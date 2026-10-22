#pragma once
// Panel configuration. Copy this file to panel_config.h and edit it there:
// panel_config.h is git-ignored, because it holds your WiFi and broker passwords.

#include <vector>

#include "machine_config.h"

// ---- Network ---------------------------------------------------------------

#define WIFI_SSID "workshop-wifi"
#define WIFI_PASSWORD "change-me"

// Your own broker, e.g. Mosquitto on a PC or Raspberry Pi on the site
// network. Never control real machines through a public test broker.
#define MQTT_HOST "192.168.1.10"
#define MQTT_PORT 1883  // usually 8883 with TLS
#define MQTT_USE_TLS 0
#define MQTT_USERNAME "panel"
#define MQTT_PASSWORD "change-me"
// With TLS: the broker's CA certificate in PEM format. Without it the
// build fails, unless MQTT_ALLOW_INSECURE_TLS is 1 (testing only: anyone
// on the network could then pose as the broker and switch machines).
#define MQTT_CA_CERT ""
#define MQTT_ALLOW_INSECURE_TLS 0

// Must match the Panel ID in the app (Settings > Network).
#define PANEL_ID "panel-3f9a1c2e"

// ---- Timing ----------------------------------------------------------------

// How often power and meter readings are published.
#define SENSOR_INTERVAL_MS 5000
// Time for a contactor to pull in or drop out before its state is
// reported. The app waits 5 s for the report.
#define CONFIRM_DELAY_MS 300
// Minimum gap between switching machines on, so motor start-up currents
// don't stack up and trip the main breaker. The app also staggers
// "Start All"; this protects against several quick taps too.
#define MIN_START_GAP_MS 2000
// An ON command sent longer ago than this (or this far in the future) is
// dropped: the app has already told the operator it failed. OFF commands
// always run. Needs the clock set by NTP; until then commands are not
// checked. 0 turns the check off.
#define CMD_MAX_AGE_MS 10000
// Time server. Use the site router or a local server if the panel has no
// internet access.
#define NTP_SERVER "pool.ntp.org"
// Local time zone (POSIX format), for dating the daily energy totals.
// "EAT-3" is East Africa Time, UTC+3.
#define TIMEZONE "EAT-3"
// Days of daily energy history kept on the broker.
#define ENERGY_KEEP_DAYS 400

// ---- PZEM-004T v3 energy meters ----------------------------------------------

// All PZEM modules share one UART (Serial2). Give each a unique Modbus
// address first: see PZEM_SET_ADDRESS below.
#define PZEM_RX_PIN 16
#define PZEM_TX_PIN 17

// Address-setting mode. Connect ONE PZEM, set this to the address to give
// it (1-247), flash, and watch the serial monitor. Set back to 0 for
// normal operation.
#define PZEM_SET_ADDRESS 0

// ---- Machines ----------------------------------------------------------------

// These match the app's demo machines. Use your machine IDs from the app.
//  id    relay  activeLow  feedback  fbActiveLow  pzem  threePhase
static const MachineConfig MACHINES[] = {
    {"1", 25, true, NO_PIN, true, 0x01, false},  // grinding machine
    {"2", 26, true, NO_PIN, true, 0x02, false},  // air compressor
    {"3", 27, true, 18, true, 0x03, true},       // welding machine
    {"4", 32, true, 19, true, 0x04, true},       // maize mill motor
    {"5", 33, true, NO_PIN, true, 0x05, false},  // borehole pump
    {"6", 13, true, NO_PIN, true, 0x06, false},  // cold room unit
};

// PZEMs on the main incomer: one for a single-phase supply, three (one per
// phase) for three-phase. Their power and energy are added together for
// the meter reading. Leave empty if there is no incomer meter.
static const std::vector<uint8_t> METER_PZEMS = {0x10, 0x11, 0x12};
