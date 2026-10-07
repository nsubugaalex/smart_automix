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
  - Without sensors, it estimates from each machine's nameplate rating
    and labels the figures as estimates.
- **UEDCL Tariff**: billing category and the rate from your current bill.
  You get a warning when the rate is over 90 days old (ERA adjusts tariffs
  quarterly), and an alert when the daily cost passes a limit you set.

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
[docs/PANEL_PROTOCOL.md](docs/PANEL_PROTOCOL.md).

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

Every push and pull request runs these checks plus a web build in GitHub
Actions (see `.github/workflows/ci.yml`).

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
