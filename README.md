# SMART-AUTOMIX

A Flutter app for a small-scale industrial switch panel in Uganda. It does
three things:

- switches workshop machines and circuits on and off remotely over MQTT;
- monitors the electrical load;
- estimates electricity costs from UEDCL/ERA tariff categories.

It runs on Android, iOS, web, Windows, macOS and Linux.

## Features

- **Control Panel**: per-machine remote on/off and a master **Cut All**
  (confirmed first).
  - **Start All** switches machines on one at a time, largest load first,
    5 seconds apart. This keeps motor start-up surges from tripping the
    main breaker.
- **Switch panel link**: commands go over MQTT, and a machine shows as
  switched **only once the panel confirms it**.
  - The app tracks whether the panel is online, using MQTT's last-will
    message.
  - Unconfirmed commands and an offline panel raise alerts.
  - **Simulation mode** (the default) lets you use the app without
    hardware.
- **Operator PIN**: needed to switch machines **on**. Switching **off** is
  never locked, so power can always be cut in an emergency.
- **Energy Monitor**: load gauge, running load (kVA), and per-machine
  current with breaker-overload warnings. Shows estimated daily and
  monthly cost in UGX.
  - If the panel has current sensors or an energy meter, the app shows
    **measured** values and today's metered energy and cost. It raises an
    **Overcurrent** alert when a machine draws more than its breaker
    allows.
  - With a meter, the app keeps a **daily energy history**: a 30-day chart
    of kWh and cost, the month-to-date total, and a table you can copy as
    CSV to check against the UEDCL bill. The panel controller keeps the
    daily totals too, so the history covers days the app was closed. Days
    with readings missing are marked.
  - Without sensors, it estimates from each machine's nameplate rating
    and labels the figures as estimates.
- **Supply protection**: with an incomer meter, the panel switches every
  machine off on low or high voltage, a lost phase or a power cut, and
  refuses starts until the supply is steady again (it never restarts
  machines itself). The app shows why on the Dashboard and Control tabs,
  alerts you, and keeps a log of faults and power cuts with their times
  and voltages, which you can copy as CSV for a complaint to UEDCL.
- **Yaka credit** (prepaid meters): record the tokens you buy and, now
  and then, the units left on the Yaka meter. The app estimates the credit
  left from the grid energy the panel measures (generator energy doesn't
  count against it) and how many days it will last at your usual use,
  warns you before it runs out, keeps the meter number to copy for mobile
  money, and shows the average price you paid per unit. Without a supply
  meter it estimates use from machine ratings and says so.
- **Unusual running (machine health)**: the app learns each machine's
  normal running current from the panel's readings (after 5 days of
  running, ignoring start-up surges) and warns when it drifts, e.g. "the
  mill has been drawing 25% more current than usual for 3 days of
  running", with likely causes for that machine type (worn bearings, blunt
  hammers, a slipping belt). It uses robust statistics (medians, not
  averages one odd day can skew), works offline and always shows what it
  compared. **Relearn normal** after a repair or new parts. Shown on the
  Maintenance screen with a chart of each machine's daily current.
- **Maintenance**: running hours per machine (counted by the panel) and
  the standby generator, with tasks due after a number of hours or days,
  e.g. "grease the mill bearings every 200 h". Suggested tasks for each
  machine type give a starting point (check the manual). Due tasks raise
  an alert and show on the Dashboard; **Done** records the hours and date.
- **Activity log**: a timeline of who switched what and when, trips,
  contactors that didn't close, changes made at the panel, supply faults,
  generator starts and the panel going offline, on the Dashboard and in
  full under **Activity** (with filters and CSV copy). Each phone sends
  the operator's name from **Settings → Profile** with its commands, so
  with several operators every phone shows who did what.
- **Panel setup**: under **Settings → Panel setup**, enter how the panel
  is wired and copy a ready-made `panel_config.h` for the firmware, with
  the panel ID, broker and machine IDs filled in from the app. It only
  offers safe ESP32 pins and checks for pins or meter addresses used twice.
- **UEDCL Tariff**: billing category and the rate from your current bill.
  You get a warning when the rate is over 90 days old (ERA adjusts tariffs
  quarterly), and an alert when the daily cost passes a limit you set.
  - **Time-of-use**: if your bill has peak and off-peak rates, enter them
    and their hours. Energy is then priced by the hour it was used. The
    Energy tab shows how your grid energy splits across the periods and
    what running peak-period work off-peak would have saved. Starting a
    large machine at peak time shows its cost per hour now and off-peak.
  - **Standby generator**: with the panel wired to the changeover switch,
    the app shows when the generator is running and counts its energy,
    run hours and fuel cost (from your fuel price and litres per kWh)
    apart from the grid, with its cost per kWh against the grid's.

## Getting started

Requires the Flutter stable SDK (3.x).

```sh
flutter pub get
flutter run -d chrome     # or windows, an Android device, ...
```

In a web debug session, use `r` / `R` in the terminal to reload. Don't
refresh the browser tab.

## Connecting a switch panel (MQTT)

The app and the panel controller connect to the same MQTT broker. The
topics, payloads and what the firmware must do are documented in
[docs/PANEL_PROTOCOL.md](docs/PANEL_PROTOCOL.md). Reference ESP32 firmware
(relays, contactor feedback, PZEM-004T power meters) is in
[firmware/esp32-panel](firmware/esp32-panel/README.md).

### Try it without hardware

1. In the app, open **Settings → Network**, choose **MQTT broker**, and tap
   **Use public test broker (demo only)**. Note the **Panel ID**.
2. Start the panel simulator with that ID:

   ```sh
   dart run tool/panel_simulator.dart --panel <panel-id>
   ```

3. Tap **Save & connect**. The app bar shows a green cloud once the panel
   is online. Switching a machine now goes through the broker to the
   simulator and back.

The simulator also publishes power and meter readings, so the Energy
Monitor shows measured values. Two options test failure handling:

- `--ignore <machine-id>`: the relay never responds.
- `--overload <machine-id>`: the machine draws 3× its rated current, which
  raises an overcurrent alert.

> The public test broker is open to everyone. Use it only for demos. Real
> installations need their own broker with authentication and TLS (see
> the protocol doc).

## Development

```sh
flutter analyze            # strict analysis (see analysis_options.yaml)
flutter test               # unit and widget tests
dart format lib test tool  # formatting (CI checks this)
```

End-to-end tests drive the real simulator through a real MQTT broker.
They are skipped unless you point them at one, for example a local
Mosquitto:

```sh
MQTT_E2E_HOST=localhost flutter test test/e2e   # MQTT_E2E_PORT if not 1883
```

Every push and pull request runs these checks, the end-to-end tests
against Mosquitto, a web build and a firmware build in GitHub Actions (see
`.github/workflows/ci.yml`).

### Project layout

| Path | Contents |
| --- | --- |
| `lib/models/` | `DeviceModel` (electrical specs, current, kVA, energy) and alerts |
| `lib/services/` | `DeviceService`, `TariffService`, `AlertService`, `SecurityService`, `PanelService`. These are `ChangeNotifier` services exposed through Provider. |
| `lib/services/panel/` | Hardware link: the `PanelLink` interface, simulated and MQTT implementations, topic contract, and connection settings |
| `lib/screens/` | `MainShell` (Dashboard / Control / Energy / Tariff tabs), Alerts, Settings (Network, Security), Add Machine |
| `lib/screens/dashboard/control_actions.dart` | The single place where the safety rules (PIN, confirmations) are applied to on/off controls |
| `lib/constants/uedcl_tariffs.dart` | Tariff categories and placeholder rates |
| `tool/panel_simulator.dart` | Command-line switch panel simulator |
| `test/` | Unit tests for models and services (MQTT tested against a fake broker), plus widget tests |
| `test/e2e/` | End-to-end tests: the app's MQTT link against the simulator through a real broker |
