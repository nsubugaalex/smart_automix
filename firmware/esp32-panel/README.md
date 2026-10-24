# ESP32 switch panel controller

Reference firmware for the SMART-AUTOMIX switch panel. It runs on an ESP32
and implements the MQTT protocol in
[docs/PANEL_PROTOCOL.md](../../docs/PANEL_PROTOCOL.md):

- switches each machine's contactor through a relay when the app says so;
- reports each machine's real state, from the contactor's auxiliary contact
  where one is wired;
- publishes power readings from PZEM-004T v3 modules, per machine and for
  the main supply.

> **Safety.** This controller is a convenience, not a safety device. The
> emergency stop and motor overload relays must be hard-wired into the
> contactor coil circuit so they work even if the ESP32 fails. The relays
> must switch **contactor coils only**, never motor current directly. Have
> a qualified electrician do the mains wiring.

## Parts

| Part | Notes |
| --- | --- |
| ESP32 DevKit (ESP32-WROOM-32) | Any `esp32dev` board |
| Relay module, one channel per machine | 5 V opto-isolated boards are common; most are *active-low* |
| Contactor per machine | Coil voltage to suit the panel, e.g. 230 V AC |
| PZEM-004T v3.0 with CT clamp, per machine (optional) | Measures one phase, up to 100 A |
| PZEM-004T v3.0 per incomer phase (optional) | For the supply meter reading |
| 5 V supply for the ESP32 and relays | A DIN-rail PSU inside the panel |

## Wiring

**Relays** (default pins, change them in `panel_config.h`):

| Machine | Relay GPIO | Feedback GPIO |
| --- | --- | --- |
| 1 Grinding machine | 25 | - |
| 2 Air compressor | 26 | - |
| 3 Welding machine | 27 | 18 |
| 4 Maize mill motor | 32 | 19 |
| 5 Borehole pump | 33 | - |
| 6 Cold room unit | 13 | - |

The relay's NO contact goes in series with the contactor coil, together
with the E-stop and the overload relay's NC contact.

**Feedback contacts** (optional, recommended for motors): wire a spare NO
auxiliary contact of the contactor between the feedback GPIO and GND. The
firmware turns on the internal pull-up, so the input reads LOW when the
contactor is closed. With feedback, the panel reports what the contactor
actually did, and it notices trips and switching at the panel.

**Generator changeover** (optional): wire an auxiliary contact of the
changeover switch that closes on the generator side between a free GPIO
and GND, and set `GENERATOR_PIN` in `panel_config.h`. Most changeover
switches and ATS units have one; use a voltage-free (dry) contact only,
never one carrying mains. The panel then publishes `grid` or `generator`
on `source`, and counts generator energy and run time separately. Put the
incomer meter PZEMs on the **load side** of the changeover, so they
measure both supplies.

**PZEM-004T modules:** all of them share one serial bus.

| PZEM | ESP32 |
| --- | --- |
| TX | GPIO 16 (RX2) |
| RX | GPIO 17 (TX2) |
| 5V | **3V3** |
| GND | GND |

Power the PZEM's TTL side from the ESP32's **3.3 V**, not 5 V. Its serial
lines are pulled up to that pin, and the ESP32's inputs are not 5 V
tolerant. Pass the CT clamp around **one phase conductor** of the machine's
supply.

Each module adds its own pull-up resistors to the shared bus. Bring the
bus up with two modules first, then add the rest one at a time, checking
the readings after each. If readings start failing as modules are added,
split the modules over two serial ports. The firmware currently uses one
(Serial2), so that would need a small change.

## Common problems to avoid

- **Relays that never fully switch off.** Many 5 V opto-isolated relay
  boards expect 5 V logic. Driven by the ESP32's 3.3 V, an active-low
  channel can stay partly on. Choose a board rated for 3.3 V inputs.
  Otherwise, on a board with a `JD-VCC` jumper, remove the jumper, feed
  `VCC` from 3V3 and `JD-VCC` from 5 V.
- **Random ESP32 resets when a contactor switches.** Contactor coils
  produce voltage spikes. Fit an RC snubber (suppressor module) across
  each AC coil, keep mains and low-voltage wiring apart, and give the
  ESP32 a decent DIN-rail 5 V supply.
- **Weak WiFi inside a steel panel.** A metal enclosure blocks the signal.
  Use an ESP32 with an external antenna connector (ESP32-WROOM-32**U**)
  and mount the antenna outside the panel. Check the signal strength
  before closing up the panel.
- **Relays clicking at boot.** Press the ESP32's reset button and power it
  off and on with the relay board connected. No relay should click. If
  one does, move it to another GPIO.

## Setup

1. Install [PlatformIO](https://platformio.org/install), either the VS Code
   extension or `pip install platformio`.
2. Copy `include/panel_config.example.h` to `include/panel_config.h` and
   set:
   - your WiFi network and password;
   - the broker address, username and password. Use your own broker (see
     *Brokers and security* in the protocol doc), never a public one with
     real machines;
   - `PANEL_ID`, from the app under **Settings → Network**;
   - the `MACHINES` table: each machine's ID exactly as the app lists it
     (**Settings → Network → Topics for the panel controller**), its pins,
     and its PZEM address.

   `panel_config.h` is git-ignored, so your passwords stay out of the
   repository.
3. **Give each PZEM its own address.** They all ship with the same one.
   For each module in turn:
   1. Connect only that module to the bus.
   2. Set `PZEM_SET_ADDRESS` to its address (e.g. `1` for machine 1, `16`
      for the first incomer phase, matching `0x10`).
   3. Flash, and check the serial monitor says it worked.

   Then set `PZEM_SET_ADDRESS` back to `0`.
4. Build and flash:

   ```sh
   cd firmware/esp32-panel
   pio run -t upload
   pio device monitor
   ```

The monitor shows the controller connecting, then `online as panel ...`.
The app's cloud icon turns green and the Energy Monitor says **Measured by
the panel**.

## How it behaves

- **Power-up:** every relay starts off, so machines never restart by
  themselves after a power cut or reboot. The controller then reports
  every machine as off.
- **Commands:** OFF happens immediately. Machines are switched ON at least
  `MIN_START_GAP_MS` (2 s) apart, so motor start-up currents don't add up
  and trip the main breaker. An OFF also cancels an ON that is still
  waiting for its turn.
- **Confirmation:** `CONFIRM_DELAY_MS` (300 ms) after switching, it reports
  the state and the machine's power reading. If a contactor doesn't close
  (no coil supply, or the E-stop is pressed), it reports OFF and releases
  the relay.
- **Trips:** if a contactor with feedback drops out by itself, the relay is
  switched off as well. The machine then stays off when the overload relay
  or E-stop is reset, until someone switches it on again.
- **Supply protection:** with incomer meter PZEMs, the controller watches
  each phase's voltage. If the supply stays below `UNDERVOLTAGE_V` (200 V)
  or above `OVERVOLTAGE_V` (255 V), loses a phase, or goes dead, for
  `SUPPLY_TRIP_DELAY_MS` (5 s), every machine is switched off. Starts are
  refused until the supply has been back in range for `SUPPLY_STABLE_MS`
  (1 min), also after power-up. Machines are never restarted automatically.
  The last 16 faults and power cuts are kept in flash and sent to the app.
  If every meter PZEM stops answering while the controller still has
  power, that counts as a power cut, so a broken meter bus also stops the
  machines (the safe way to fail).
- **Hourly and generator energy:** each day's total is split by local
  hour for grid energy (for time-of-use pricing), with generator energy
  and run time counted apart.
- **Daily energy:** with a supply meter, the controller totals each
  day's energy (local time, `TIMEZONE`) and publishes it, retained, to
  `energy/<date>`, so the app's history covers days it wasn't open. The
  running total is saved to flash every 10 minutes and survives a
  restart. It needs the clock from NTP, like the late-command check.
  The broker keeps `ENERGY_KEEP_DAYS` (400) days.
- **Late commands:** an `ON` that arrives more than 10 s after the app
  sent it (`CMD_MAX_AGE_MS`) is ignored, and the app reports that the panel
  didn't confirm. `OFF` always runs. This needs the clock set over NTP
  (`NTP_SERVER`; use the site router if there's no internet). Until it is
  set, commands aren't checked. A phone whose clock is wrong by more than
  10 s can't switch machines on, and the serial log says so.
- **Lost connection:** if the WiFi or broker connection drops, machines stay
  as they are. The broker tells the app the panel is offline (last will).
  The controller reconnects automatically. Commands sent while it was
  offline are discarded rather than run late.
- **Readings:** published every `SENSOR_INTERVAL_MS` (5 s). The PZEMs are
  read one per loop pass, never all in a row, so a trip or E-stop is still
  noticed within about 100 ms while readings are being taken. A PZEM that
  doesn't answer is skipped, and the app falls back to an estimate for that
  machine. On three-phase machines, the power from the one measured phase
  is multiplied by 3, which assumes a balanced load.
- **TLS:** set `MQTT_USE_TLS 1`, the TLS port, and the broker's CA
  certificate in `MQTT_CA_CERT`. The build fails without a CA certificate,
  unless you set `MQTT_ALLOW_INSECURE_TLS 1` (testing only).
- **Watchdog:** if the controller stops responding for 30 s it restarts,
  and a restart leaves every machine off.
