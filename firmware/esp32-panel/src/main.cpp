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
//   command can't switch a machine hours later. An ON that arrives more
//   than CMD_MAX_AGE_MS after the app sent it is dropped as well.
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
#include <ArduinoJson.h>
#include <MQTT.h>
#include <PZEM004Tv30.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <esp_task_wdt.h>
#include <sys/time.h>
#include <time.h>

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
#ifndef CMD_MAX_AGE_MS
#define CMD_MAX_AGE_MS 10000
#endif
#ifndef NTP_SERVER
#define NTP_SERVER "pool.ntp.org"
#endif
#ifndef TIMEZONE
#define TIMEZONE "EAT-3"
#endif
#ifndef ENERGY_KEEP_DAYS
#define ENERGY_KEEP_DAYS 400
#endif
#ifndef GENERATOR_PIN
#define GENERATOR_PIN NO_PIN
#define GENERATOR_ACTIVE_LOW true
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
const String kEnergyPrefix = kBase + "/energy/";
const String kSourceTopic = kBase + "/source";

constexpr size_t kMachineCount = sizeof(MACHINES) / sizeof(MACHINES[0]);
constexpr uint32_t kReconnectIntervalMs = 5000;
constexpr uint32_t kFeedbackDebounceMs = 100;
// Restart if loop() stops running (e.g. stuck in the network stack). The
// restart switches every machine off, so this is far longer than any
// normal blocking call: MQTT connect (2 s), TLS handshake (10 s).
constexpr uint32_t kWatchdogTimeoutS = 30;
constexpr uint32_t kTlsHandshakeTimeoutS = 10;
// Before this (Nov 2023) the clock hasn't been set by NTP yet.
constexpr time_t kMinValidEpochS = 1700000000;
// Today's energy is published this often, and saved to flash this often
// (constant writes wear flash out; after a restart, the register increase
// since the last save is still counted).
constexpr uint32_t kEnergyPublishMs = 60 * 1000;
constexpr uint32_t kEnergySaveMs = 10 * 60 * 1000;

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
// Room for a day's energy message with its 24 hourly values.
MQTTClient mqtt(1024);

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

// ---- Supply source -----------------------------------------------------------

constexpr uint32_t kSourceDebounceMs = 500;
bool onGenerator = false;
bool sourceRaw = false;
uint32_t sourceChangedAt = 0;

bool hasGeneratorInput() { return GENERATOR_PIN != NO_PIN; }

bool readGenerator() {
  return (digitalRead(GENERATOR_PIN) == HIGH) != GENERATOR_ACTIVE_LOW;
}

void publishSource() {
  if (!hasGeneratorInput() || !mqtt.connected()) return;
  mqtt.publish(kSourceTopic, onGenerator ? "generator" : "grid",
               /*retained=*/true, /*qos=*/1);
}

// Follow the changeover switch, debounced.
void watchSource(uint32_t now) {
  if (!hasGeneratorInput()) return;
  const bool raw = readGenerator();
  if (raw != sourceRaw) {
    sourceRaw = raw;
    sourceChangedAt = now;
    return;
  }
  if (raw == onGenerator || now - sourceChangedAt < kSourceDebounceMs) return;
  onGenerator = raw;
  log(raw ? "supply: generator" : "supply: grid");
  publishSource();
}

// ---- Daily energy ------------------------------------------------------------
//
// The controller is always on, so it keeps the day-by-day energy total for
// the app: each meter reading adds the register increase since the last one
// to the current local day. Each day is a retained message on
// energy/<YYYY-MM-DD>, so the app gets the whole history when it connects.
// Grid energy is split by local hour, so the app can price it at
// time-of-use rates; energy while on the generator is counted apart.

struct EnergyDay {
  char date[11] = "";  // local date, YYYY-MM-DD; empty = none yet
  double kwh = 0;      // grid and generator
  double lastRegKwh = 0;
  int64_t firstAt = 0;  // first and last reading, seconds since 1970
  int64_t lastAt = 0;
  float gridHourlyKwh[24] = {};
  double generatorKwh = 0;
  uint32_t generatorSeconds = 0;
};

// Readings further apart than this are a gap (controller off), not
// generator run time.
constexpr int64_t kMaxReadingGapS = 10 * 60;

Preferences energyStore;
EnergyDay energyToday;
// The previous day, until it has been published as finished.
EnergyDay energyPrevious;
bool previousPublished = true;
uint32_t lastEnergyPublish = 0;
uint32_t lastEnergySave = 0;

void localDate(time_t t, char out[11]) {
  tm local;
  localtime_r(&t, &local);
  strftime(out, 11, "%Y-%m-%d", &local);
}

void saveEnergy() {
  energyStore.putBytes("today", &energyToday, sizeof(energyToday));
  energyStore.putBytes("prev", &energyPrevious, sizeof(energyPrevious));
  energyStore.putBool("prevSent", previousPublished);
}

void loadEnergy() {
  energyStore.begin("energy", /*readOnly=*/false);
  // A size mismatch means a different firmware layout: start afresh.
  if (energyStore.getBytesLength("today") == sizeof(energyToday)) {
    energyStore.getBytes("today", &energyToday, sizeof(energyToday));
  }
  if (energyStore.getBytesLength("prev") == sizeof(energyPrevious)) {
    energyStore.getBytes("prev", &energyPrevious, sizeof(energyPrevious));
    previousPublished = energyStore.getBool("prevSent", true);
  }
}

bool publishEnergyDay(const EnergyDay &day) {
  if (day.date[0] == '\0' || !mqtt.connected()) return false;
  char payload[640];
  int n = snprintf(
      payload, sizeof(payload),
      "{\"kwh\":%.3f,\"reg\":%.3f,\"first\":%lld,\"last\":%lld,"
      "\"g\":%.3f,\"gs\":%lu,\"h\":[",
      day.kwh, day.lastRegKwh, static_cast<long long>(day.firstAt),
      static_cast<long long>(day.lastAt), day.generatorKwh,
      static_cast<unsigned long>(day.generatorSeconds));
  for (int h = 0; h < 24 && n < static_cast<int>(sizeof(payload)); h++) {
    n += snprintf(payload + n, sizeof(payload) - n, h ? ",%.3f" : "%.3f",
                  day.gridHourlyKwh[h]);
  }
  if (n >= static_cast<int>(sizeof(payload)) - 2) return false;
  strcpy(payload + n, "]}");
  return mqtt.publish(kEnergyPrefix + day.date, payload, /*retained=*/true,
                      /*qos=*/1);
}

// Publish what the app doesn't have yet: the finished previous day (if it
// ended while offline) and today so far.
void publishEnergy(uint32_t nowMs) {
  if (!previousPublished && publishEnergyDay(energyPrevious)) {
    previousPublished = true;
    // Retained history is kept for ENERGY_KEEP_DAYS: remove the day that
    // just dropped out of it.
    char expired[11];
    localDate(time(nullptr) - static_cast<time_t>(ENERGY_KEEP_DAYS) * 86400,
              expired);
    mqtt.publish(kEnergyPrefix + expired, "", /*retained=*/true, /*qos=*/1);
  }
  if (publishEnergyDay(energyToday)) lastEnergyPublish = nowMs;
}

void recordEnergy(double registerKwh, uint32_t nowMs) {
  const time_t now = time(nullptr);
  if (now < kMinValidEpochS) return;  // no date until NTP has set the clock
  char today[11];
  localDate(now, today);

  if (strcmp(today, energyToday.date) != 0) {
    // A new day. Energy between the old day's last reading and this one
    // isn't counted for either (seconds, unless the controller was off).
    if (energyToday.date[0] != '\0') {
      energyPrevious = energyToday;
      previousPublished = false;
    }
    energyToday = EnergyDay();
    strcpy(energyToday.date, today);
    energyToday.lastRegKwh = registerKwh;
    energyToday.firstAt = energyToday.lastAt = now;
    saveEnergy();
    lastEnergySave = nowMs;
    publishEnergy(nowMs);
    return;
  }

  // A register that went backwards was replaced or reset: carry on from
  // its new value without adding anything.
  if (registerKwh > energyToday.lastRegKwh) {
    const double added = registerKwh - energyToday.lastRegKwh;
    energyToday.kwh += added;
    if (onGenerator) {
      energyToday.generatorKwh += added;
    } else {
      tm local;
      localtime_r(&now, &local);
      energyToday.gridHourlyKwh[local.tm_hour] += added;
    }
  }
  const int64_t gap = now - energyToday.lastAt;
  if (onGenerator && gap > 0 && gap <= kMaxReadingGapS) {
    energyToday.generatorSeconds += gap;
  }
  energyToday.lastRegKwh = registerKwh;
  energyToday.lastAt = now;
  if (nowMs - lastEnergySave >= kEnergySaveMs) {
    saveEnergy();
    lastEnergySave = nowMs;
  }
  if (nowMs - lastEnergyPublish >= kEnergyPublishMs) publishEnergy(nowMs);
}

// One PZEM read takes ~100 ms, so a sweep of all of them would leave trips
// unnoticed for a second or more. Instead each loop() pass reads at most
// one PZEM: first each machine's, then the incomer meter's.
struct SensorSweep {
  bool active = false;
  size_t step = 0;
  float meterWatts = 0;
  double meterKwh = 0;  // float rounds a 5-digit register to 0.01
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
    // Read even while offline: the daily energy keeps counting.
    if (!sweep.meterValid) return;
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
  if (meterPzems.empty() || !sweep.meterValid) return;
  recordEnergy(sweep.meterKwh, now);
  if (!mqtt.connected()) return;
  char payload[64];
  snprintf(payload, sizeof(payload), "{\"w\":%.1f,\"kwh\":%.3f}",
           sweep.meterWatts, sweep.meterKwh);
  mqtt.publish(kMeterTopic, payload, /*retained=*/false, /*qos=*/0);
}

// ---- MQTT --------------------------------------------------------------------

// Milliseconds since 1970, or 0 while the clock isn't set by NTP yet.
int64_t epochMs() {
  timeval tv;
  gettimeofday(&tv, nullptr);
  if (tv.tv_sec < kMinValidEpochS) return 0;
  return static_cast<int64_t>(tv.tv_sec) * 1000 + tv.tv_usec / 1000;
}

// The app sends {"cmd":"ON","ts":<ms since 1970>}. Plain ON/OFF is
// accepted too (manual testing, older apps); its sentAtMs is 0.
bool parseCommand(const String &payload, Request &request, int64_t &sentAtMs) {
  String cmd = payload;
  sentAtMs = 0;
  if (payload.startsWith("{")) {
    JsonDocument doc;
    if (deserializeJson(doc, payload)) return false;
    cmd = doc["cmd"] | "";
    sentAtMs = doc["ts"] | static_cast<int64_t>(0);
  }
  cmd.trim();
  cmd.toUpperCase();
  if (cmd == "ON") {
    request = Request::On;
  } else if (cmd == "OFF") {
    request = Request::Off;
  } else {
    return false;
  }
  return true;
}

// Whether to drop an ON that arrived too late (or, if the clocks disagree,
// too early). OFF is never dropped: stopping is the safe direction.
bool isStaleStart(const String &id, Request request, int64_t sentAtMs) {
  if (request != Request::On || sentAtMs <= 0 || CMD_MAX_AGE_MS <= 0) {
    return false;
  }
  const int64_t now = epochMs();
  if (now == 0) {
    static bool warned = false;
    if (!warned) {
      warned = true;
      log("clock not set by NTP yet: command age not checked");
    }
    return false;
  }
  const int64_t age = now - sentAtMs;
  if (llabs(age) <= CMD_MAX_AGE_MS) return false;
  log("machine " + id + ": ON sent " + String(static_cast<long>(age / 1000)) +
      " s ago ignored (too late, or the phone's clock is wrong)");
  return true;
}

// Called from mqtt.loop(). The MQTT library must not publish from inside
// its callback, so this only records the request for loop() to act on.
void onMessage(String &topic, String &payload) {
  if (!topic.startsWith(kMachinesPrefix) || !topic.endsWith("/set")) return;
  const String id =
      topic.substring(kMachinesPrefix.length(), topic.length() - 4);
  Request request;
  int64_t sentAtMs;
  if (!parseCommand(payload, request, sentAtMs)) return;
  for (auto &m : machines) {
    if (id == m.cfg->id) {
      // No state report: the app then shows "did not confirm".
      if (isStaleStart(id, request, sentAtMs)) return;
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
  publishSource();
  publishEnergy(millis());
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
  if (hasGeneratorInput()) {
    pinMode(GENERATOR_PIN, INPUT_PULLUP);
    onGenerator = sourceRaw = readGenerator();
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
  loadEnergy();

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
  // Syncs in the background once WiFi is up; used for command ages and
  // to date the daily energy (in local time).
  configTzTime(TIMEZONE, NTP_SERVER);

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
  watchSource(now);
  stepSensors(now);
  delay(10);
}
