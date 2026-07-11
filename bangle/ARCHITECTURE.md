# Bangle.js Firmware — Architecture

Four files, each with a specific job. If you've read the comments in `app.js`
asking "why do we have this" or "how does this work" — this doc is the answer.

## The four files

| File | Runs when | Job |
|---|---|---|
| `lib.js` | `require("pulsewatch")` is called | The actual recording engine — HRM listener, buffering, file saving, BLE streaming |
| `boot.js` | Every time the watch boots | Decides whether to auto-load `lib.js`, based on a saved setting |
| `widget.js` | Every time the watch boots | Draws the green recording dot, and *also* loads `lib.js` if recording is enabled |
| `app.js` | User opens the PulseWatch app from the launcher | Shows the settings/status menu (start/stop, files, storage used, etc.) |

**Why both `boot.js` and `widget.js` load the library** — this looks redundant
but isn't quite: `boot.js` runs first during Espruino's boot sequence, before
widgets are drawn. `widget.js` runs as part of widget loading and needs the
library loaded too so the green dot logic and the recording engine agree on
state. In practice only one of them actually ends up calling `require()` in
a way that matters (Espruino caches modules — a second `require("pulsewatch")`
for an already-loaded module is a cheap no-op, not a second copy), so this
isn't a bug, just a "belt and suspenders" pattern from having two independent
entry points into the same boot sequence.

**What `require("pulsewatch")` actually returns** — Espruino modules run once
and cache their `exports` object. `lib.js` is saved onto the watch under the
name `pulsewatch` (no `.js` extension — that's what turns it into a
`require`-able module rather than a launcher app). The first time anything
calls `require("pulsewatch")`, `lib.js` runs top to bottom, including its
last line, `exports.reload()` — which is what actually starts recording if
the saved setting says to. Every *subsequent* `require("pulsewatch")` call
(from `boot.js`, `widget.js`, or `app.js`) just hands back the same cached
`exports` object (`start`, `stop`, `isRecording`, `getStatus`,
`deleteAllData`, `reload`) without re-running the file. That's why `app.js`
can call `pw.getStatus()` freely — it's just reading state off the one
shared instance, not creating a new one.

## Recording lifecycle

```
Watch boots
  │
  ▼
boot.js / widget.js check pulsewatch.json's "recording" flag
  │
  ├─ true  → require("pulsewatch") → lib.js runs → exports.reload() → exports.start()
  └─ false → nothing happens, HRM sensor stays off
```

```
exports.start()                              exports.stop()
  │                                             │
  ├─ Bangle.on('HRM', onHRM)                    ├─ clearInterval(liveFlushTimer)
  ├─ Bangle.setHRMPower(1, "pulsewatch")        ├─ flushLiveBuffer()  (send anything queued)
  └─ setInterval(flushLiveBuffer, 15s)          ├─ saveData()         (flush to flash)
                                                 ├─ Bangle.removeListener('HRM', onHRM)
                                                 └─ Bangle.setHRMPower(0, "pulsewatch")
```

`onHRM(hrm)` fires roughly once per second while the HRM sensor is powered
on. Each call:
1. Reads the current accelerometer reading (`Bangle.getAccel()`)
2. Builds a data point: timestamp, BPM, RR interval (if the sensor reported
   one — falls back to `0` if not), confidence, and the three accel axes
3. Pushes it into **two** separate buffers — see below

## Two buffers, two purposes

- **`dataBuffer`** — accumulates until `saveInterval` (5 minutes) has
  elapsed, then `saveData()` writes it to a new `pw<timestamp>.csv` file in
  flash and clears the buffer. This is the durable, full-fidelity copy —
  it exists regardless of whether a phone is connected over BLE at all.
- **`liveBuffer`** — accumulates until `liveFlushInterval` (15 seconds) has
  elapsed, then `flushLiveBuffer()` sends everything queued as one
  multi-line BLE transmission and clears the buffer.

They're deliberately separate: the flash buffer is the ground truth (synced
later via the app's file-transfer flow), while the live buffer is a
best-effort, low-latency feed for the phone's live UI and on-device risk
scoring. Batching the live buffer instead of sending one BLE packet per
sample (the old behavior) cuts radio wake-ups roughly 15x, since a BLE
transmission's fixed per-event overhead is far more expensive than just
holding 15 seconds of readings in RAM.

## Why the app needs to reassemble BLE data

A single CSV line (`1702396800123,72,833,85,100,-50,980`, ~30-40 characters)
routinely exceeds one BLE notification's payload size. `Bluetooth.println()`
on this side doesn't guarantee one notification per line — the phone side
(`ble_service.dart`) has to buffer incoming bytes and only process complete,
`\n`-terminated lines, carrying over any partial line to the next
notification. This matters more now that `flushLiveBuffer()` sends up to 15
lines in a single call.

## Auto-start when the phone connects

The watch itself doesn't know when a phone connects — that trigger lives on
the Flutter side. When `ble_service.dart` successfully connects to a
Bangle.js device, it sends the literal command string
`require("pulsewatch").start()` over the UART TX characteristic, which the
watch executes as JavaScript. That's the "how does it start automatically"
answer from the old `app.js` comment — it's not automatic on the watch's
side at all, it's the phone telling the watch to start once it's paired.

## Configuration

`CONFIG` at the top of `lib.js`:

```js
const CONFIG = {
  saveInterval: 5 * 60 * 1000,      // how often to flush dataBuffer to flash
  liveFlushInterval: 15 * 1000,     // how often to batch-send liveBuffer over BLE
  appName: "pulsewatch"
};
```

## Accessing data directly (debugging)

Via the Bangle.js Web IDE console:

```js
require('Storage').list(/^pw/)                 // list all data files
require('Storage').open('pw1702396800123.csv', 'r').read(1000)  // read a file
require('Storage').readJSON('pulsewatch.json')  // check recording settings
```
