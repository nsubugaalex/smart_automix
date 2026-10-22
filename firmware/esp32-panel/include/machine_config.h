#pragma once

#include <stdint.h>

// No GPIO pin / no PZEM module.
constexpr int8_t NO_PIN = -1;
constexpr uint8_t NO_PZEM = 0;

// One machine (contactor) on the panel.
struct MachineConfig {
  // Machine ID, exactly as the app lists it under
  // Settings > Network > Topics for the panel controller.
  const char *id;

  // GPIO driving the relay that energises the contactor coil.
  int8_t relayPin;
  // Most relay boards switch on when the input is pulled LOW.
  bool relayActiveLow;

  // Optional GPIO reading the contactor's auxiliary (NO) contact, so the
  // panel reports what the contactor actually did, and notices trips and
  // switching at the panel. NO_PIN to report the relay state instead.
  int8_t feedbackPin;
  // True if the input reads LOW when the contactor is closed (contact
  // wired to GND with the internal pull-up).
  bool feedbackActiveLow;

  // Modbus address of this machine's PZEM-004T, or NO_PZEM.
  uint8_t pzemAddress;

  // Three-phase machine: the PZEM measures one phase, so the reported
  // power is that phase's power x 3 (assumes a balanced load). The
  // current is reported as measured, i.e. the line current.
  bool threePhase;
};
