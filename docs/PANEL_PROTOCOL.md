# Switch panel MQTT protocol

This is the contract between the SMART-AUTOMIX app and a switch panel
controller (for example an ESP32 driving relay/contactor boards; a
reference implementation is in
[`firmware/esp32-panel`](../firmware/esp32-panel/README.md)). The app
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
| `smartautomix/<panel>/machines/<machine>/set` | app → panel | `{"cmd": "ON", "ts": 1792656000000}` | 1 | no |
| `smartautomix/<panel>/machines/<machine>/state` | panel → app | `ON` or `OFF` | 1 | **yes** |
| `smartautomix/<panel>/status` | panel → app | `online` or `offline` | 1 | **yes** |
| `smartautomix/<panel>/machines/<machine>/event` | panel → app | `{"on": false, "cause": "trip", "by": "", "src": ""}` | 1 | no |
| `smartautomix/<panel>/machines/<machine>/power` | panel → app | `{"w": 6800, "a": 11.2}` | 0 | no |
| `smartautomix/<panel>/meter` | panel → app | `{"w": 9100, "kwh": 48211.7}` | 0 | no |
| `smartautomix/<panel>/energy/<YYYY-MM-DD>` | panel → app | `{"kwh": 79.9, "reg": 48211.7, "first": 1792616405, "last": 1792702795, "g": 4.2, "gs": 3600, "h": [24 values]}` | 1 | **yes** |
| `smartautomix/<panel>/source` | panel → app | `grid` or `generator` | 1 | **yes** |
| `smartautomix/<panel>/supply` | panel → app | `{"state": "undervoltage", "since": 1792616405}` | 1 | **yes** |
| `smartautomix/<panel>/supply/events` | panel → app | `[{"kind": "outage", "phase": 1, "from": …, "to": …, "min": 0, "max": 0}]` | 1 | **yes** |

`state` and `status` payloads are plain text, matched case-insensitively.
A command's `cmd` is `ON` or `OFF`, and `ts` is when the app sent it, in
milliseconds since 1970 (UTC). Commands may also carry `by` (the
operator's name, from **Settings → Profile**) and `src` (a random tag for
the app install); the controller only passes them back in its events.
Controllers should also accept a plain
`ON`/`OFF` command payload, which is handy for testing with
`mosquitto_pub`. The `power` and `meter` topics are optional and only used if the panel has sensors
(see [Power and energy readings](#power-and-energy-readings)).

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
   - **Drop a late `ON`.** If `ts` is more than 10 seconds away from the
     controller's clock, in either direction, ignore an `ON` and send no
     report, so the app shows "did not confirm". Otherwise a delayed
     message could start a machine after the operator was told the
     command failed. Always carry out `OFF`, whatever its age. Skip the
     check while the controller's clock isn't set (no NTP yet).
5. **Report local changes too.** If a machine is switched at the panel, or
   tripped by a breaker, publish its new state so the app stays correct.
6. **Say why it changed** (optional, for the app's activity log). After
   each state change, publish to the machine's `event` topic, not retained:
   - `on`: the new state;
   - `cause`: `command` (from an app), `trip` (the contactor dropped out:
     overload relay or E-stop), `panel` (switched at the panel),
     `supply` (supply protection), `no_close` (told to start, but the
     contactor didn't close) or `refused` (a start refused because of the
     supply);
   - `by` and `src`: copied from the command, for `command`, `no_close` and
     `refused`; empty otherwise.

   Without events, the app still logs each change, but can only say it was
   made "at the panel or from another phone".

## Power and energy readings

These topics are optional. Without them the app estimates the load from
each machine's nameplate rating, and labels it as an estimate.

- **`machines/<machine>/power`**: what one machine draws right now, from a
  current sensor (CT clamp) or a meter module such as a PZEM-004T.
  - `w`: real power in watts.
  - `a`: line current in amps. On a three-phase machine, report the
    current in one phase (or the average of the three), not the sum.
- **`meter`**: the main supply, measured at the incomer.
  - `w`: total real power in watts, including loads the app doesn't
    switch.
  - `kwh`: the meter's cumulative energy register. It only ever goes up,
    except when the meter is replaced or reset.

Both are JSON objects with numeric values of 0 or more. Messages with a
missing, negative or non-numeric value are ignored.

What the controller should do:

1. **Publish every 5 seconds** while connected, with QoS 0 and **not
   retained**. A retained reading would show an old value as if it were
   live.
2. **Report every machine that has a sensor, including machines that are
   off** (`{"w": 0, "a": 0}`). This tells the app the sensor is working.
3. **Publish a machine's reading straight after switching it**, so the
   app doesn't keep showing the old value for up to 5 seconds.

The app treats a reading as live for **30 seconds**. After that it goes
back to estimating that machine, so a failed sensor never leaves a frozen
value on screen. A machine measured drawing more current than its breaker
rating raises an **Overcurrent** alert.

The app also counts each day's energy itself, from the `kwh` register,
but only while it's open. If the app was closed at midnight, today only
counts from the first reading it gets, and the app shows when that was.

### Daily energy totals

The controller is always on, so it should keep the daily totals. Then the
app's history is complete even for days nobody had it open.

- **`energy/<YYYY-MM-DD>`**: one message per local calendar day, **retained**
  so the app gets the whole history when it connects.
  - `kwh`: energy that day: the sum of the register's increases between
    readings. A register that goes backwards (meter replaced) adds nothing.
  - `reg`: the register at the last reading. The app's live readings
    carry on from this value, so nothing is counted twice.
  - `first`, `last`: the first and last reading of the day, in seconds
    since 1970. The app marks a day incomplete unless they are within 15
    minutes of its midnights.
  - `h` (optional): grid kWh in each of the 24 local hours. With it, the
    app prices the day at time-of-use rates hour by hour.
  - `g`, `gs` (optional): kWh used while on the standby generator, and
    seconds on generator. Generator energy is part of `kwh` but not of
    `h`, and the app prices it at fuel cost, not the UEDCL rate.
- Publish today's message about once a minute, and the finished day once
  more just after midnight (on reconnecting, if the controller was offline
  then).
- Keep the running total in non-volatile memory, so a restart doesn't lose
  the day.
- To keep the broker tidy, delete days older than the history you keep by
  publishing an empty retained message to their topic.

### Supply protection (optional)

With an incomer meter, the controller should protect the machines from a
bad supply on its own, without needing the app or the network:

- **Watch each phase's voltage.** Add the voltages to the `meter` message as
  `"v": [231.0, 229.4, 230.2]` (one per phase; 0 for a phase that didn't
  answer).
- **Trip** when the supply stays out of range for a few seconds (long
  enough to ride through a motor's start-up dip): low voltage, high
  voltage, a lost phase, or every phase dead. Switch every machine off
  (publishing their states as usual) and refuse starts.
- **Allow starts again** only once the supply has been back in range and
  steady for a while. Never restart machines automatically. Start in the
  `settling` state after power-up for the same reason.
- **`supply`** (retained): the state, one of `ok`, `settling`,
  `undervoltage`, `overvoltage`, `phase_loss`, `outage`, and `since`, when
  it began (seconds since 1970, 0 if the clock isn't set).
- **`supply/events`** (retained): the recent faults and power cuts, oldest
  first: `kind` (as above), `phase` (1-3), `from` and `to` (seconds since
  1970; `to` is 0 while it lasts) and the lowest and highest voltage seen.
  Log a power cut that switched the controller off too, once it is back.

The app shows the state on the Dashboard and Control tabs, refuses starts
while the panel would, and alerts on faults. It keeps a longer log than
the controller, and can copy it as CSV for a complaint to UEDCL.

### Supply source (optional)

If the panel has a standby generator, publish `grid` or `generator` to
`source` (retained) whenever the changeover switch moves, and on
connecting. Read it from an auxiliary contact on the changeover switch.
The app shows when the generator is running, and counts its energy, run
time and fuel cost apart from the grid. The meter must be on the load side
of the changeover, so it measures both supplies.

The app uses the panel's total for a day unless it counted more itself
(for example, a new controller that started partway through the day).

## What the app does

- Subscribes to the panel's `status` topic and all `state` topics. Retained
  messages give it the current state immediately on connecting. Also
  subscribes to the `power` and `meter` topics.
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
  from the internet. Give the app and the panel separate accounts, and
  restrict each with ACLs (see below).
- **The operator PIN is checked only in the app.** Anyone with an account
  that may publish to a `set` topic can switch machines on without it.
  Only give app accounts to people trusted to run the machines.
- The web version of the app can only use WebSockets. A page served over
  `https` can only connect with `wss://` (TLS).

### Example Mosquitto ACLs

For panel `panel-3f9a1c2e`, with accounts `site1-panel` (the controller)
and `site1-app` (the app). Each account may only publish what its side of
the protocol sends, so the app can't fake machine states and the panel
can't issue commands:

```text
# /etc/mosquitto/acl  (set acl_file and password_file in mosquitto.conf)

user site1-panel
topic read  smartautomix/panel-3f9a1c2e/machines/+/set
topic write smartautomix/panel-3f9a1c2e/machines/+/state
topic write smartautomix/panel-3f9a1c2e/machines/+/power
topic write smartautomix/panel-3f9a1c2e/meter
# Also covers the last will
topic write smartautomix/panel-3f9a1c2e/status

user site1-app
topic write smartautomix/panel-3f9a1c2e/machines/+/set
topic read  smartautomix/panel-3f9a1c2e/machines/+/state
topic read  smartautomix/panel-3f9a1c2e/machines/+/power
topic read  smartautomix/panel-3f9a1c2e/meter
topic read  smartautomix/panel-3f9a1c2e/status
```

Create the accounts with `mosquitto_passwd -c /etc/mosquitto/passwd
site1-panel` and then `mosquitto_passwd /etc/mosquitto/passwd site1-app`.
Mosquitto 2.x also needs `allow_anonymous false` and a `listener` line.

## Testing without hardware

`tool/panel_simulator.dart` behaves like a controller that follows this
protocol:

```sh
# Use the panel ID shown in the app under Settings > Network
dart run tool/panel_simulator.dart --panel panel-3f9a1c2e

# Simulate a relay that never responds (machine 5)
dart run tool/panel_simulator.dart --panel panel-3f9a1c2e --ignore 5

# Simulate a jammed mill motor drawing 3x its rated current (machine 4)
dart run tool/panel_simulator.dart --panel panel-3f9a1c2e --overload 4
```

The simulator publishes power and meter readings every 5 seconds, using
the ratings of the app's demo machines plus about 5% random variation.
It also publishes today's energy total. Add `--history-days 30` to
publish made-up totals for the last 30 days as well, to fill the app's
history chart (and adds a few past power cuts to the supply log).
`--supply-fault undervoltage:30:20` simulates 20 s of low voltage starting
30 s after launch (also `overvoltage`, `phase_loss`, `outage`), to see
supply protection trip and recover; `--trip-delay-s` and `--stable-s`
shorten its timings. `--generator-hours 19-22` runs on the generator between
those hours (and gives history days some generator use), to try the
generator tracking. Use `--interval-s` to change how often, or
`--no-sensors` to try the app without readings.

Stop it with Ctrl+C and it reports `offline`. If you kill it outright, the
broker publishes its last will after about 30 seconds.
