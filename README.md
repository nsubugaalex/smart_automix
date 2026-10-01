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

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
