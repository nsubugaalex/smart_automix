# smart_automix

A Flutter app for a small-scale industrial switch panel: remote on/off control
of workshop machines and circuits, live load monitoring, and electricity cost
estimation based on UEDCL/ERA tariff categories (Uganda).

## Status

The app currently manages machines/circuits and cost estimates in-app
(local storage). It assumes a generic MQTT-controlled relay panel for the
actual hardware side — no specific relay/firmware is wired up yet.

- **Control Panel** — master cut-off and per-machine remote on/off.
- **Energy Monitor** — live load gauge, daily energy (kWh) and estimated
  UGX cost.
- **UEDCL Tariff** — pick a billing category (Domestic, Commercial, Small/
  Medium Industrial) and enter the rate from your current UEDCL bill, since
  ERA adjusts tariffs quarterly and there is no public UEDCL API to pull
  live rates from.

## Getting Started

```sh
flutter pub get
flutter run          # pick a device (Android, Windows, Chrome, ...)
flutter test
flutter analyze
```

## Project layout

- `lib/models/` — machine (`DeviceModel`) and alert models
- `lib/services/` — `DeviceService`, `TariffService`, `AlertService`
  (`ChangeNotifier` singletons, persisted with `shared_preferences`)
- `lib/screens/` — `MainShell` with the Dashboard / Control / Energy /
  Tariff tabs, plus Alerts, Settings and Add Machine
- `lib/constants/uedcl_tariffs.dart` — tariff categories and placeholder rates
