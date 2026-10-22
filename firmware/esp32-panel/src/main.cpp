// SMART-AUTOMIX switch panel controller (ESP32).
//
// Implements the MQTT protocol in docs/PANEL_PROTOCOL.md: switches machine
// contactors on ON/OFF commands from the app, reports each machine's real
// state, and publishes power readings from PZEM-004T modules.
//
// Safety behaviour:
// - All relays start OFF at power-up, so machines never restart by
//   themselves after a power cut or reboot.
// - Commands are not queued while offline (clean MQTT session), so an old
//   command can't switch a machine hours later.
// - Losing WiFi or the broker leaves machines as they are.
// - Machines are switched on at least MIN_START_GAP_MS apart.
// - A watchdog restarts the controller if it hangs; like any restart,
//   that leaves every machine OFF.
// - If a contactor with a feedback contact drops out by itself (overload
//   relay, E-stop, coil supply lost), its relay is switched off too, so
//   the machine stays off until someone switches it on again.
//
// The emergency stop and motor overload protection must be hard-wired in
// the contactor coil circuit. This controller is not a safety device.

#include <Arduino.h>
#include <MQTT.h>
#include <PZEM004Tv30.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <esp_task_wdt.h>

#if __has_include("panel_config.h")
#include "panel_config.h"
#else
#warning "include/panel_config.h not found: using panel_config.example.h"
#include "panel_config.example.h"
#endif

// Older panel_config.h files predate this option.
#ifndef MQTT_ALLOW_INSECURE_TLS
#define MQTT_ALLOW_INSECURE_TLS 0
#endif

#if MQTT_USE_TLS
static_assert(sizeof(MQTT_CA_CERT) > 1 || MQTT_ALLOW_INSECURE_TLS,
              "MQTT_USE_TLS needs the broker's CA certificate in MQTT_CA_CERT "
              "(or MQTT_ALLOW_INSECURE_TLS 1, for testing only)");
#endif

namespace {

const String kBase = String("smartautomix/") + PANEL_ID;
const String kStatusTopic = kBase + "/status";
const String kMeterTopic = kBase + "/meter";
const String kMachinesPrefix = kBase + "/machines/";

constexpr size_t kMachineCount = sizeof(MACHINES) / sizeof(MACHINES[0]);
constexpr uint32_t kReconnectIntervalMs = 5000;
constexpr uint32_t kFeedbackDebounceMs = 100;
// Restart if loop() stops running (e.g. stuck in the network stack). The
// restart switches every machine off, so this is far longer than any
// normal blocking call: MQTT connect (2 s), TLS handshake (10 s).
constexpr uint32_t kWatchdogTimeoutS = 30;
constexpr uint32_t kTlsHandshakeTimeoutS = 10;

enum class Request : int8_t { None, Off, On };

struct Machine {
  const MachineConfig *cfg = nullptr;
  PZEM004Tv30 *pzem = nullptr;
  bool relayOn = false;
  // Set by the MQTT callback, acted on in loop().
  volatile Request request = Request::None;
  // Waiting for the contactor to settle before reporting its state.
  bool confirmPending = false;
  uint32_t confirmAt = 0;
  // Last state published to the app.
  bool reportedOn = false;
  // Debounced feedback contact.
  bool feedbackOn = false;
  bool feedbackRaw = false;
  uint32_t feedbackChangedAt = 0;
};

Machine machines[kMachineCount];
std::vector<PZEM004Tv30 *> meterPzems;

#if MQTT_USE_TLS
WiFiClientSecure net;
#else
WiFiClient net;
#endif
MQTTClient mqtt(512);

uint32_t lastConnectAttempt = 0;
uint32_t lastSensorPublish = 0;
uint32_t lastStartAt = 0;
bool startedAny = false;

void log(const String &message) {
  Serial.printf("[%8lu] %s\n", static_cast<unsigned long>(millis()),
                message.c_str());
}

// ---- Relays and feedback -----------------------------------------------------

void setRelay(Machine &m, bool on) {
  m.relayOn = on;
  const bool level = on != m.cfg->relayActiveLow;
  digitalWrite(m.cfg->relayPin, level ? HIGH : LOW);
}

bool readFeedback(const Machine &m) {
  const bool high = digitalRead(m.cfg->feedbackPin) == HIGH;
  return high != m.cfg->feedbackActiveLow;
}

bool hasFeedback(const Machine &m) { return m.cfg->feedbackPin != NO_PIN; }

// The machine's real state: the contactor's feedback contact if fitted,
// otherwise what the relay was told to do.
bool actualState(const Machine &m) {
  return hasFeedback(m) ? m.feedbackOn : m.relayOn;
}

// ---- Publishing --------------------------------------------------------------

void publishState(Machine &m) {
  const bool on = actualState(m);
  m.reportedOn = on;
  if (!mqtt.connected()) return;
  mqtt.publish(kMachinesPrefix + m.cfg->id + "/state", on ? "ON" : "OFF",
               /*retained=*/true, /*qos=*/1);
}

void publishPower(Machine &m) {
  if (m.pzem == nullptr || !mqtt.connected()) return;
  float watts = m.pzem->power();
  const float amps = m.pzem->current();
  // A failed read is skipped; the app shows an estimate after 30 s.
  if (isnan(watts) || isnan(amps)) return;
  if (m.cfg->threePhase) watts *= 3;
  char payload[64];
  snprintf(payload, sizeof(payload), "{\"w\":%.1f,\"a\":%.2f}", watts, amps);
  mqtt.publish(kMachinesPrefix + m.cfg->id + "/power", payload,
               /*retained=*/false, /*qos=*/0);
}

// One PZEM read takes ~100 ms, so a sweep of all of them would leave trips
// unnoticed for a second or more. Instead each loop() pass reads at most
// one PZEM: first each machine's, then the incomer meter's.
struct SensorSweep {
  bool active = false;
  size_t step = 0;
  float meterWatts = 0;
  float meterKwh = 0;
  bool meterValid = true;
};

SensorSweep sweep;

void stepSensors(uint32_t now) {
  if (!sweep.active) {
    if (now - lastSensorPublish < SENSOR_INTERVAL_MS) return;
    lastSensorPublish = now;
    sweep = SensorSweep();
    sweep.active = true;
  }
  while (sweep.step < kMachineCount &&
         machines[sweep.step].pzem == nullptr) {
    sweep.step++;
  }
  if (sweep.step < kMachineCount) {
    publishPower(machines[sweep.step++]);
    return;
  }
  const size_t meterIndex = sweep.step - kMachineCount;
  if (meterIndex < meterPzems.size()) {
    sweep.step++;
    if (!sweep.meterValid || !mqtt.connected()) {
      sweep.meterValid = false;
      return;
    }
    auto *pzem = meterPzems[meterIndex];
    const float w = pzem->power();
    const float e = pzem->energy();
    // A partial sum would understate the load, so skip the whole reading.
    if (isnan(w) || isnan(e)) {
      sweep.meterValid = false;
      return;
    }
    sweep.meterWatts += w;
    sweep.meterKwh += e;
    return;
  }
  sweep.active = false;
  if (meterPzems.empty() || !sweep.meterValid || !mqtt.connected()) return;
  char payload[64];
  snprintf(payload, sizeof(payload), "{\"w\":%.1f,\"kwh\":%.3f}",
           sweep.meterWatts, sweep.meterKwh);
  mqtt.publish(kMeterTopic, payload, /*retained=*/false, /*qos=*/0);
}

// ---- MQTT --------------------------------------------------------------------

// Called from mqtt.loop(). The MQTT library must not publish from inside
// its callback, so this only records the request for loop() to act on.
void onMessage(String &topic, String &payload) {
  if (!topic.startsWith(kMachinesPrefix) || !topic.endsWith("/set")) return;
  const String id =
      topic.substring(kMachinesPrefix.length(), topic.length() - 4);
  payload.trim();
  payload.toUpperCase();
  Request request;
  if (payload == "ON") {
    request = Request::On;
  } else if (payload == "OFF") {
    request = Request::Off;
  } else {
    return;
  }
  for (auto &m : machines) {
    if (id == m.cfg->id) {
      m.request = request;
      return;
    }
  }
  log("command for unknown machine " + id + " ignored");
}

void connectMqtt() {
  const String clientId = String("smartautomix-panel-") + PANEL_ID;
  log("connecting to MQTT broker " MQTT_HOST "...");
  // If this controller loses power or network, the broker tells the app.
  mqtt.setWill(kStatusTopic.c_str(), "offline", /*retained=*/true,
               /*qos=*/1);
  const bool ok = strlen(MQTT_USERNAME) > 0
                      ? mqtt.connect(clientId.c_str(), MQTT_USERNAME,
                                     MQTT_PASSWORD)
                      : mqtt.connect(clientId.c_str());
  if (!ok) {
    log(String("MQTT connect failed, error ") + mqtt.lastError() +
        ", return code " + mqtt.returnCode());
    return;
  }
  mqtt.subscribe(kMachinesPrefix + "+/set", /*qos=*/1);
  mqtt.publish(kStatusTopic, "online", /*retained=*/true, /*qos=*/1);
  // Tell the app the real state of every machine straight away.
  for (auto &m : machines) publishState(m);
  log("online as panel " PANEL_ID);
}

void maintainConnection(uint32_t now) {
  if (mqtt.connected() || WiFi.status() != WL_CONNECTED) return;
  if (lastConnectAttempt != 0 &&
      now - lastConnectAttempt < kReconnectIntervalMs) {
    return;
  }
  lastConnectAttempt = now;
  connectMqtt();
}

// ---- Control -----------------------------------------------------------------

void startConfirm(Machine &m, uint32_t now) {
  m.confirmPending = true;
  m.confirmAt = now + CONFIRM_DELAY_MS;
}

void processRequests(uint32_t now) {
  for (auto &m : machines) {
    const Request request = m.request;
    if (request == Request::Off) {
      m.request = Request::None;  // also cancels a waiting ON
      setRelay(m, false);
      log(String("machine ") + m.cfg->id + ": OFF");
      startConfirm(m, now);
    } else if (request == Request::On) {
      if (m.relayOn) {
        m.request = Request::None;
        startConfirm(m, now);  // already on: just confirm it
        continue;
      }
      if (startedAny && now - lastStartAt < MIN_START_GAP_MS) {
        continue;  // wait for the start gap; stays requested
      }
      m.request = Request::None;
      setRelay(m, true);
      lastStartAt = now;
      startedAny = true;
      log(String("machine ") + m.cfg->id + ": ON");
      startConfirm(m, now);
    }
  }
}

void processConfirmations(uint32_t now) {
  for (auto &m : machines) {
    if (!m.confirmPending || static_cast<int32_t>(now - m.confirmAt) < 0) {
      continue;
    }
    m.confirmPending = false;
    if (hasFeedback(m)) {
      // Take the contact as it is now, without waiting for the debounce.
      m.feedbackOn = m.feedbackRaw = readFeedback(m);
      m.feedbackChangedAt = now;
      if (m.relayOn && !m.feedbackOn) {
        log(String("machine ") + m.cfg->id +
            ": contactor did not close; check the coil supply and E-stop");
        setRelay(m, false);
      }
    }
    publishState(m);
    publishPower(m);  // the app sees the new draw straight away
  }
}

// Notice contactors that changed by themselves: tripped, E-stop, or
// switched at the panel.
void watchFeedback(uint32_t now) {
  for (auto &m : machines) {
    if (!hasFeedback(m) || m.confirmPending) continue;
    const bool raw = readFeedback(m);
    if (raw != m.feedbackRaw) {
      m.feedbackRaw = raw;
      m.feedbackChangedAt = now;
      continue;
    }
    if (raw == m.feedbackOn || now - m.feedbackChangedAt < kFeedbackDebounceMs) {
      continue;
    }
    m.feedbackOn = raw;
    if (!raw && m.relayOn) {
      // Latch off, so the machine doesn't restart when the overload relay
      // or E-stop is reset.
      setRelay(m, false);
      log(String("machine ") + m.cfg->id + ": contactor dropped out (trip?)");
    } else {
      log(String("machine ") + m.cfg->id + ": switched " +
          (raw ? "ON" : "OFF") + " at the panel");
    }
    publishState(m);
    publishPower(m);
  }
}

// ---- Setup -------------------------------------------------------------------

#if PZEM_SET_ADDRESS
void setupPzemAddressMode() {
  log("PZEM address mode: setting the connected PZEM to address " +
      String(PZEM_SET_ADDRESS));
  PZEM004Tv30 pzem(Serial2, PZEM_RX_PIN, PZEM_TX_PIN);  // general address
  if (!pzem.setAddress(PZEM_SET_ADDRESS)) {
    log("failed. Check the wiring and that only one PZEM is connected.");
  } else {
    log("done: the PZEM now reports address " + String(pzem.readAddress()) +
        ". Set PZEM_SET_ADDRESS back to 0 and flash again.");
  }
  for (;;) delay(1000);
}
#endif

}  // namespace

void setup() {
  // Relays first, so contactors are never energised during boot. Setting
  // the level before switching the pin to an output avoids a glitch.
  for (size_t i = 0; i < kMachineCount; i++) {
    Machine &m = machines[i];
    m.cfg = &MACHINES[i];
    digitalWrite(m.cfg->relayPin, m.cfg->relayActiveLow ? HIGH : LOW);
    pinMode(m.cfg->relayPin, OUTPUT);
    setRelay(m, false);
    if (hasFeedback(m)) {
      pinMode(m.cfg->feedbackPin, INPUT_PULLUP);
      m.feedbackOn = m.feedbackRaw = readFeedback(m);
    }
  }

  Serial.begin(115200);
  log("SMART-AUTOMIX panel " PANEL_ID " starting, all machines OFF");

#if PZEM_SET_ADDRESS
  setupPzemAddressMode();
#endif

  for (auto &m : machines) {
    if (m.cfg->pzemAddress != NO_PZEM) {
      m.pzem = new PZEM004Tv30(Serial2, PZEM_RX_PIN, PZEM_TX_PIN,
                               m.cfg->pzemAddress);
    }
  }
  for (const uint8_t address : METER_PZEMS) {
    meterPzems.push_back(
        new PZEM004Tv30(Serial2, PZEM_RX_PIN, PZEM_TX_PIN, address));
  }

#if MQTT_USE_TLS
  if (strlen(MQTT_CA_CERT) > 0) {
    net.setCACert(MQTT_CA_CERT);
  } else {
    log("WARNING: TLS without a CA certificate; the broker is not verified");
    net.setInsecure();
  }
  net.setHandshakeTimeout(kTlsHandshakeTimeoutS);
#endif

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  log("connecting to WiFi " WIFI_SSID "...");

  mqtt.begin(MQTT_HOST, MQTT_PORT, net);
  mqtt.onMessage(onMessage);
  mqtt.setKeepAlive(15);
  mqtt.setCleanSession(true);
  mqtt.setTimeout(2000);

  esp_task_wdt_init(kWatchdogTimeoutS, /*panic=*/true);
  esp_task_wdt_add(nullptr);  // this (the loop) task
}

void loop() {
  esp_task_wdt_reset();
  mqtt.loop();
  const uint32_t now = millis();
  maintainConnection(now);
  processRequests(now);
  processConfirmations(now);
  watchFeedback(now);
  stepSensors(now);
  delay(10);
}
