# Switch panel MQTT protocol

This is the contract between the SMART-AUTOMIX app and a switch panel
controller (for example an ESP32 driving relay/contactor boards). The app
and the controller never talk directly: both connect to the same MQTT
broker. The topic names are defined in code in
[`lib/services/panel/panel_topics.dart`](../lib/services/panel/panel_topics.dart).

## Identifiers

- **Panel ID**: identifies one installation, for example `panel-3f9a1c2e`.
  The app generates a random one on first run. It is shown, and can be
  edited, under **Settings → Network**. It must be 3–40 characters from
  `A–Z a–z 0–9 - _`.
- **Machine ID**: the ID of each machine in the app. The app lists these
  under **Settings → Network → Topics for the panel controller**. The
  controller maps each machine ID to a relay output.

## Topics

| Topic | Direction | Payload | QoS | Retained |
| --- | --- | --- | --- | --- |
| `smartautomix/<panel>/machines/<machine>/set` | app → panel | `ON` or `OFF` | 1 | no |
| `smartautomix/<panel>/machines/<machine>/state` | panel → app | `ON` or `OFF` | 1 | **yes** |
| `smartautomix/<panel>/status` | panel → app | `online` or `offline` | 1 | **yes** |

Payloads are plain text. `ON`/`OFF` are matched case-insensitively.

## What the controller must do

1. **Connect with a last will** on `smartautomix/<panel>/status`, with
   payload `offline`, retained, QoS 1. If the controller loses power or
   network, the broker then tells the app automatically.
2. **After connecting, publish `online`** (retained) to the same status
   topic.
3. **Publish the real state of every machine** to its `state` topic
   (retained) at start-up, so the app shows the truth as soon as it
   connects.
4. **Subscribe to `smartautomix/<panel>/machines/+/set`.** When a command
   arrives, switch the relay. Then publish the resulting state to the
   machine's `state` topic, retained.
   - Report the state **after** switching. If the contactor has an
     auxiliary contact or a current sensor, report what it reads, not
     what was commanded.
   - The app waits **5 seconds** for this report. If none arrives, it shows
     "did not confirm" and leaves the machine in its previous state.
5. **Report local changes too.** If a machine is switched at the panel, or
   tripped by a breaker, publish its new state so the app stays correct.

## What the app does

- Subscribes to the panel's `status` topic and all `state` topics. Retained
  messages give it the current state immediately on connecting.
- Shows a machine as switched **only when its `state` report arrives**.
- Shows the connection status in the app bar. It raises a critical alert
  when the broker is unreachable or the panel reports `offline`.
- Never needs a PIN to switch a machine **off**. Switching **on** can be
  protected by the operator PIN (**Settings → Security**).

## Brokers and security

- **Demo:** the public test broker `broker.emqx.io` (TCP 1883, WebSocket 8083
  at `/mqtt`, TLS 8883 / 8084). **Anyone can publish to a public broker,**
  so use it only with the simulator, never with real machines.
- **Real installations:** run your own broker, for example Mosquitto on a
  Raspberry Pi or PC on the site network, or a hosted broker. Enable
  username/password authentication, and TLS whenever the broker is reachable
  from the internet. Restrict each account with ACLs to its own
  `smartautomix/<panel>/#` topics.
- The web version of the app can only use WebSockets. A page served over
  `https` can only connect with `wss://` (TLS).

## Testing without hardware

`tool/panel_simulator.dart` behaves like a controller that follows this
protocol:

```sh
# Use the panel ID shown in the app under Settings > Network
dart run tool/panel_simulator.dart --panel panel-3f9a1c2e

# Simulate a relay that never responds (machine 5)
dart run tool/panel_simulator.dart --panel panel-3f9a1c2e --ignore 5
```

Stop it with Ctrl+C and it reports `offline`. If you kill it outright, the
broker publishes its last will after about 30 seconds.
