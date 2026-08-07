# Bangle.js Firmware — Architecture

Four files, each with a specific job. If you've read the comments in `app.js`
asking "why do we have this" or "how does this work" — this doc is the answer.

## The four files

| File | Runs when | Job |
|---|---|---|
| `lib.js` | `require("pulsewatch")` is called | The actual recording engine — HRM listener, buffering, file saving |
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
  ├─ Bangle.on('HRM', onHRM)                    ├─ saveData()         (flush to flash)
  └─ Bangle.setHRMPower(1, "pulsewatch")        ├─ Bangle.removeListener('HRM', onHRM)
                                                 └─ Bangle.setHRMPower(0, "pulsewatch")
```

`onHRM(hrm)` fires roughly once per second while the HRM sensor is powered
on. Each call:
1. Reads the current accelerometer reading (`Bangle.getAccel()`)
2. Builds a data point: timestamp, BPM, RR interval (if the sensor reported
   one — falls back to `0` if not), confidence, and the three accel axes
3. Pushes it into `dataBuffer`

## One buffer, one purpose

- **`dataBuffer`** — accumulates until `saveInterval` (5 minutes) has
  elapsed, then `saveData()` writes it to a new `pw<timestamp>.csv` file in
  flash and clears the buffer. This is the durable, full-fidelity copy —
  it exists regardless of whether a phone is connected over BLE at all, and
  it's the *only* copy: there used to also be a `liveBuffer` that batch-sent
  samples over BLE every 15s for a live phone-side UI, but that added a
  second code path (and a live-vs-file-sync disambiguation hack on the phone
  side, since live and file-echoed data are byte-identical in shape) for a
  feature that wasn't load-bearing for the actual risk-score pipeline. Data
  now reaches the phone exclusively via the file-sync flow below.

  `saveData()` writes with a single plain `Storage.write(filename, csvText)`
  call — not `Storage.open(filename, "w")` (`StorageFile`, a *chunked*
  writer). This matters a lot: `StorageFile` stores content under
  `"<filename>\1"`, `"\2"`, etc. — Espruino appends a raw chunk-number byte
  as the file's last character — and `Storage.list()`'s default output
  includes that suffix, which silently broke every `.csv$`-anchored regex
  in this codebase (this file, `app.js`'s status menu, and the phone's
  sync request all use one). The old code wrote real files that permanently
  consumed flash and were never found, read, or erased by anything,
  because nothing could match a name that didn't cleanly end in `.csv`. A
  plain write avoids chunking entirely — comfortably, since a single
  5-minute buffer is at most ~300 rows (~12KB), far under any real size
  limit that would justify `StorageFile`. `cleanupGhostStorageFiles()`
  (runs once, automatically, the first time this fixed `lib.js` loads —
  gated by a flag in `pulsewatch.json` so it never re-scans after
  succeeding) finds and erases any files written by the old buggy code,
  using `Storage.list(regex, {sf: true})` to explicitly ask for
  `StorageFile`-flagged entries the default listing can't see.

## Why the app needs to reassemble BLE data

A single CSV line (`1702396800123,72,833,85,100,-50,980`, ~30-40 characters)
routinely exceeds one BLE notification's payload size. The phone side
(`ble_service.dart`) has to buffer incoming bytes and only process complete,
`\n`-terminated lines, carrying over any partial line to the next
notification — this applies to the file-sync read response (a whole file's
content, printed line by line), which is now the only thing arriving over
this characteristic besides command echoes.

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
  appName: "pulsewatch"
};
```

## Accessing data directly (debugging)

Via the Bangle.js Web IDE console:

```js
require('Storage').list(/^pw/)                 // list all data files
require('Storage').read('pw1702396800123.csv')  // read a file
require('Storage').readJSON('pulsewatch.json')  // check recording settings
require('Storage').list(/^pw/, {sf: true})      // list any pre-fix ghost StorageFile chunks
```

## Version

`VERSION` at the top of `lib.js` is logged as `PulseWatch vX.XX loaded`
every time the library loads — keep it in sync with `metadata.json`'s
`"version"` and the top `ChangeLog` entry. This is what makes "which
firmware is actually on the watch" answerable from the BLE console instead
of inferred from behavior.
