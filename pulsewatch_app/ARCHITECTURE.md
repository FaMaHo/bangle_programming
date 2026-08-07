# Flutter App — Architecture

## Structure

```
lib/
├── main.dart                    # App entry point + top-level routing
├── theme/app_theme.dart         # Colors, shared styling (AppColors)
├── screens/                     # One file per screen
└── services/                    # Business logic, no UI — screens call into these
```

Screens hold UI state and call services; services hold logic and know nothing
about widgets. `main.dart` is the only place that decides *which* screen is
currently visible.

## App-level routing (`main.dart`)

`_AppEntry` is the root widget and owns four states, checked in order:

```
not logged in?        → EnrollScreen or LoginScreen (toggled via internal state,
                         NOT Navigator.push — see note below)
logged in, app-lock
enabled but locked?    → LockScreen
otherwise              → MainNavigation (the four-tab bottom nav)
```

**Why Enroll/Login toggle via `setState` instead of `Navigator.push`:** an
earlier version pushed one screen on top of the other with
`Navigator.pushReplacement`. Since both screens were being rendered as the
app's *root* route, replacing one with the other actually disposed the
`_AppEntry` widget that owned the "you're logged in now" callback — so
successfully logging in after switching screens had no live listener to
react to it (looked like the login button did nothing). `_AppEntry` now owns
`_showLogin` as a boolean and swaps between `EnrollScreen`/`LoginScreen`
directly in its own `build()`, so its state — and the callback — survives
the whole flow.

`MainNavigation` holds the four bottom-nav tabs (Home, Insights, Device,
Upload) and also handles: auto-upload on app resume, and reconnecting to the
last-known BLE device on resume.

## Screens

| Screen | Purpose |
|---|---|
| `home_screen.dart` | Dashboard: watch status, 48h collection progress, live BPM + signal quality, upload nudge, and the risk report card (locked until 48h of data is collected, then triggers `report_service.dart`'s one-time full-session scoring). |
| `report_screen.dart` | Full cardiac risk report — gauge, risk level/assessment, session overview, top contributing features with clinical descriptions. Pushed from the home screen once a report exists. |
| `insights_screen.dart` | 7-day trends: daily presence, HR stats, average signal quality, days-recorded progress. |
| `device_screen.dart` | BLE scan/connect/disconnect, signal quality (from real HRM confidence, not a synthetic score). |
| `server_screen.dart` | "Upload" tab — server URL/connection test, data stats, consent-gated export & upload. Deliberately does *not* hold account/settings UI (see `settings_screen.dart`). |
| `settings_screen.dart` | Account info, log out, biometric app-lock toggle. Split out from `server_screen.dart` — the upload page is about *where data goes*, this page is about *who the user is*. |
| `enroll_screen.dart` | First-run: turn a researcher/website-issued enrollment code into an account (username + password). |
| `login_screen.dart` | Returning-user login. |
| `lock_screen.dart` | Biometric/PIN gate, shown on launch and whenever the app returns from the background if app-lock is enabled. |

## Services

| Service | Purpose |
|---|---|
| `auth_service.dart` | Enrollment/login/refresh, token storage via `flutter_secure_storage`. |
| `ble_service.dart` | Scanning, connecting, parsing incoming Bangle.js/T-Watch data, BLE line reassembly (see below). Singleton (`BleService()` factory always returns the same instance). |
| `background_sync_service.dart` | Schedules/cancels the periodic WorkManager task that syncs the watch when the app isn't open — see "Background sync" below. |
| `sync_log_service.dart` | Persisted, capped log of connect/sync attempts (success/failure, stage, message) — see "Background sync" below. |
| `connection_status_service.dart` | Persisted, isolate-safe record of the watch link's real state (connected/reconnecting/disconnected) — drives the live notification content and the interactive sync timer's staleness check. See "Background sync" below. |
| `database_helper.dart` | Local SQLite (`sqflite`) — `heart_rate`, `accelerometer`, `sessions` tables. |
| `hrv_feature_extractor.dart` | Computes the 22 HRV/accel features the AI model expects from a window of samples. |
| `inference_service.dart` | Runs the on-device ONNX model (`assets/models/model.onnx`) to turn features into a risk score for one window. |
| `report_service.dart` | Owns the one-time full-session report: pulls the last 48h from the DB, slides 5-min/50%-overlap windows across all of it, averages the per-window probabilities into a session score, persists the result, and fires the risk alert/alarm once. |
| `server_service.dart` | Server URL config, CSV export, upload, auto-upload eligibility. |
| `biometric_lock_service.dart` | Wraps `local_auth` for the app-lock feature. |
| `notification_service.dart` | Local push notification when a risk alert fires. |

## Data flow: watch → screen

```
BLE notification (Bangle.js UART)
  │
  ▼
ble_service.dart: _uartCarry buffer reassembles fragments into complete lines
  │  (a BLE packet routinely splits a ~35-char CSV line mid-field — see
  │   bangle/ARCHITECTURE.md for why the firmware can't guarantee whole lines
  │   per packet)
  ▼
Parse "timestamp,bpm,rr_interval_ms,confidence,x,y,z"
  │
  ▼
database_helper.dart: insertHeartRateWithTimestamp / insertAccelerometerWithTimestamp
  (durable local storage; also drives the live BPM card and the "X/48h
  collected" progress bar on Home — but NOT risk scoring, see below)
```

```
home_screen.dart: _loadStats() (polled every 10s)
  │
  ▼ once getHourlyMeanHR(48).length >= 48 and no report exists yet
report_service.dart: computeReport()
  │
  ├─► database_helper.dart: getHRWithAccelSince(now - 48h)
  │        (joins heart_rate/accelerometer on an exact timestamp match —
  │         the firmware stamps both rows in one onHRM() tick with the same
  │         integer timestamp, see bangle/lib.js. This must stay an
  │         equality join: a fuzzy `abs(diff) < 500` range join can't use
  │         the timestamp indexes and turns into an O(n·m) nested-loop scan
  │         that never finishes at 48h/~170k-row scale — caught by
  │         test/report_flow_test.dart, which seeds a realistic 1Hz 48h+
  │         session in the exact wire format above and runs the real
  │         on-device ONNX model against it end-to-end.)
  │
  ├─► hrv_feature_extractor.dart: compute() per 5-min/50%-overlap window
  │        across the whole session, computeNocturnal() once for the
  │        session-level circadian features
  │
  ├─► inference_service.dart: getRiskScore() per window
  │        → session score = mean(window probabilities), matching how the
  │          model was trained/evaluated (fromDaria/generate_report_html.py)
  │
  └─► persists the report (shared_preferences) and fires
      NotificationService.sendRiskAlert() / BleService.sendRiskAlarm() once
```

`BpmSample` carries the watch's own timestamp (not phone receipt time) and,
when the watch reported one, the real RR interval — `HrvFeatureExtractor`
uses the real RR value when available and only falls back to a
`60000/bpm` approximation for samples that don't have one (e.g. older data,
or T-Watch, which has no RR output).

The risk score is deliberately **not** live — it's computed once, from the
full 48h session, the first time `home_screen.dart` observes 48h of
coverage. Earlier this scored a single 5-minute window every 2 minutes
starting 5 minutes after connecting; that used too little data to be
trustworthy (several features were always at training-set defaults) and
produced unreliable high-risk false positives, so it was replaced with the
full-session approach above.

## Background sync

The watch (`bangle/lib.js`) checkpoints buffered readings to flash every 5
minutes on its own, independent of whether anything is connected
(`CONFIG.saveInterval`). Getting that data onto the phone is split into two
paths that both funnel through the same `BleService.connectToDevice()` /
`syncDataFromWatch()` logic:

```
Interactive (app open)                  Background (app closed/backgrounded)
────────────────────────                ─────────────────────────────────────
User taps Connect, or                   WorkManager fires a periodic task
app resumes from background             (~every 15 min, Android's enforced
        │                                floor for periodic work)
        ▼                                        │
connectToDevice(autoConnect: …)                   ▼
  fire-and-forget sync                  BleService.performBackgroundSync()
  (device_screen shows a                  - no "am I already connected" check
  "connecting…" spinner, so                 (see note below — every reported
  a long backlog sync shouldn't              connection state turned out to
  block it — see                            be a guess that real testing
  transferProgressStream)                    proved unreliable)
                                            - unconditionally: force-disconnect
                                              via BluetoothDevice.fromId(id)
                                              (works even though this isolate
                                              never made the connection
                                              itself) → NO scan (see note 4
                                              below — the watch is bonded, so
                                              BluetoothDevice.fromId(id) +
                                              connect(autoConnect: true) hands
                                              reconnection to Android's own
                                              background whitelist scanning)
                                              → AWAIT syncDataFromWatch() →
                                              disconnect (awaitSync: true —
                                              WorkManager needs a definite
                                              pass/fail to decide whether to
                                              back off and retry, unlike the
                                              interactive
                                              fire-and-forget path)
```

This — not the foreground service — is what bounds how far the phone can
fall behind the watch: at most ~15-30 minutes, indefinitely, regardless of
whether the app process or foreground service survives that long. It
replaced an earlier design that tried to hold one BLE connection open
continuously for the full 48h backed only by a foreground service; that
fights Android directly (Doze can still defer/drop connections under a
foreground service, and the service itself isn't guaranteed to survive the
app being swiped from Recents), so on a real device it produced exactly the
failure mode this section is meant to prevent — the watch recording ~2000
readings over 48h while the phone only picked up the ~100 or so from the
brief windows the app happened to be open. The foreground service still
runs (for the UX benefit of a slightly stickier connection while
interactively connected, and briefly during each background sync's bounded
window — Android 12+ generally wants a foreground service around active BLE
work triggered from the background), but a failure to start it is now
logged and non-fatal rather than reported as a failed connection.

Every stage of the connect → characteristics → sync → foreground-service
pipeline in `connectToDevice()` is logged individually via
`SyncLogService` (success or failure, with a specific message — not a
generic "connection failed"), tagged with whether it came from an
interactive or background attempt. `device_screen.dart` surfaces the most
recent ~10 entries in an expandable "Sync diagnostics" card and shows the
real failure reason in the connect snackbar, so a background failure that
happened unattended is still diagnosable afterward without `adb logcat`.

`RECEIVE_BOOT_COMPLETED` (declared in `AndroidManifest.xml`) lets
WorkManager restore this schedule after the phone reboots mid-session.

**Every "am I connected" signal turned out to be a guess, and every guess
was eventually wrong — so `performBackgroundSync()` stopped asking.** This
went through three iterations, each caught by real multi-hour device
testing:

1. **First bug**: `performBackgroundSync()` originally skipped its own
   reconnect attempt whenever `FlutterForegroundTask.isRunningService` was
   true, on the assumption that meant an interactive session already owned
   the link. But the service was only ever stopped by an explicit
   `disconnect()` call, so an *unexpected* drop (watch out of range,
   OS/watch silently killing the GATT link) left a stale "Connected"
   notification up for a connection that no longer existed — and every
   periodic sync in between saw `isRunningService == true` and skipped,
   producing multi-hour gaps bounded only by how long it took the user to
   notice and reopen the app.

   Fixed by replacing "service alive" with a real, persisted, isolate-safe
   `WatchConnectionState` (`connection_status_service.dart`;
   disconnected/connecting/connected/reconnecting), written by
   `connectToDevice()`/its connectionState listener on every real
   transition — `performBackgroundSync()` moved to checking that instead.

2. **Second bug**: that state can itself lie. Android's BLE stack can keep
   reporting a link as "connected" for hours after it's actually gone
   silently dead — a zombie GATT client that answers connect()/
   discoverServices() calls but never delivers notifications again, while
   the watch keeps recording the entire time. `ConnectionStatusService.isStale()`
   was added to catch this (no new DB reading in N minutes despite
   believing we're connected ⇒ force a teardown+reconnect), and
   `performBackgroundSync()`'s stale branch called `disconnect()` to tear
   down the zombie link before retrying.

   That teardown call was itself broken: `performBackgroundSync()` runs in
   the WorkManager background isolate, which has its own fresh
   `BleService()` singleton with its own empty `_connectedDevice` (always
   `null` there — this isolate never made the connection itself, some
   *other* isolate did, possibly hours earlier). `disconnect()`'s
   `if (_connectedDevice != null)` guard was therefore always false in this
   context, silently no-opping — Android was never actually told to release
   the link. A real multi-hour test confirmed the failure mode exactly:
   every background wake logged `isStale() == true`, "forcing a fresh
   reconnect", and then a scan that found nothing, indefinitely — because
   the watch, still genuinely connected at the native level, had stopped
   advertising (a connected BLE peripheral normally does), so no scan could
   ever find it. Interactive reconnects kept working throughout, because
   that path runs in the *same* isolate that holds the real
   `_connectedDevice` reference.

   Fixed with `BluetoothDevice.fromId(savedId).disconnect()` — Android
   tracks GATT connections by remote address, not Dart object identity, so
   constructing a device reference from just the saved ID and disconnecting
   *that* releases the same real link regardless of which isolate created
   it or which isolate is now trying to tear it down.

3. **Final simplification**: rather than trust *any* reported connection
   state to decide whether background sync is safe to skip, it stopped
   asking entirely. `performBackgroundSync()` no longer calls `isStale()`
   or checks `WatchConnectionState` at all — every cycle unconditionally
   force-disconnects (best-effort, harmless if there was nothing real to
   tear down) and then attempts a fresh connect+sync. This isn't reckless:
   SQLite's `UNIQUE(timestamp, device_id)` + insert-ignore
   (`database_helper.dart`) and the watch's erase-only-after-confirmed-insert
   already make repeated/overlapping sync attempts harmless, so there was
   nothing the skip check was protecting against that isn't already handled
   at the data layer — and removing it also removes the entire class of bug
   that steps 1 and 2 were spent fixing. The one accepted tradeoff: if an
   *interactive* session has a genuinely healthy connection open right now,
   a background cycle's forced disconnect will briefly interrupt it — the
   interactive side's own autoConnect + connectionState listener already
   reconnects automatically within moments of any drop, planned or not, so
   this is a brief hiccup rather than a lasting failure.

`isStale()` is still used — just not by `performBackgroundSync()` anymore.
The *interactive* sync timer (`BleService`'s 2-minute periodic re-sync
while the app is open) still calls it to decide when to force its own
watchdog reconnect, since that path genuinely does hold a live
`_connectedDevice` reference and a real disconnect there is not a no-op.

4. **The actual remaining problem: the watch was never bonded, so Android's
   background scan throttling had free rein.** Even with steps 1-3 fixed
   and verified on genuinely fresh code, live testing kept showing
   `performBackgroundSync()` scan attempts fail with "not in range" —
   sometimes seeing *zero* BLE devices of any kind in a 25s window (not
   just missing the watch), while every interactive scan from the same
   phone succeeded instantly. `adb shell dumpsys bluetooth_manager`
   confirmed why: the watch never appeared in the phone's bonded-devices
   list — every connection all along had been a bare, unbonded GATT
   connection negotiated from scratch each time. This is the real
   structural difference from how actual smartwatch companion apps (Fitbit,
   Garmin, etc.) achieve reliable background sync: they bond/pair with the
   phone, which lets Android's own low-power, whitelist-based background
   scanning — built specifically for reconnecting to known/bonded
   companion devices — handle reconnection at the native Bluetooth stack
   level. An unbonded device gets none of that; it's subject to the same
   aggressive background-scan throttling as any ad-hoc device discovery.

   Fixed with two changes:
   - `connectToDevice()` now calls `device.createBond()` (idempotent — a
     no-op once already bonded) after every successful connect, so the
     watch becomes a known/bonded device from the very first successful
     interactive connect onward. This shows Android's system pairing
     prompt the first time it runs — Bangle.js uses "Just Works" BLE
     pairing (no PIN), so it's a simple confirmation, not a code-entry
     flow.
   - `performBackgroundSync()` no longer scans at all. It constructs a
     `BluetoothDevice` directly from the saved remote ID
     (`BluetoothDevice.fromId(savedId)` — no discovery needed to build this
     reference) and calls `connectToDevice(..., autoConnect: true)`
     directly, handing reconnection entirely to Android's native
     `autoConnect` mechanism rather than an app-initiated `startScan()`.
     The autoConnect wait is a separate, longer timeout
     (`autoConnectTimeout`, 60s for background vs. the 15s interactive
     default) since it now has to cover Android's own background
     whitelist-scan latency, not just a GATT handshake with an
     already-discovered device — still comfortably within WorkManager's
     4-minute hard ceiling.

   Verified on a real device after this fix: 3 consecutive background
   syncs succeeded, each firing right on WorkManager's ~15-minute
   schedule, connecting within 9-28 seconds of waking — the first genuine
   background-sync successes of the entire debugging session.

A few more follow-on changes came out of this same testing round:

- **Immediate OS-level reconnect on an unexpected drop.** Previously
  nothing attempted to reconnect until either the user reopened the app or
  the next WorkManager tick (up to ~15-30 min later) — the listener now
  re-issues `device.connect(autoConnect: true)` the instant a drop is
  detected, which doesn't poll/scan, just registers with the Android
  Bluetooth stack to complete the moment the watch is back in range.
- **The foreground service is now a live, continuously-running status
  board**, not a one-shot banner. It stays up from first connect until an
  explicit `disconnect()` (default `stopForegroundService: true`) —
  `performBackgroundSync()` passes `stopForegroundService: false` so its
  end-of-cycle disconnect only drops the radio, not the notification.
  `ConnectionStatusService.updateNotification()` refreshes the title/text
  on every state change and, via `foreground_task_handler.dart`'s
  `onRepeatEvent` (every 60s), keeps "last reading Xm ago" current even
  when nothing else changes — replacing what the user correctly identified
  as a hardcoded notification that never reflected real state.
- **Proof the background task actually fires.** `background_sync_service.dart`
  now logs an unconditional `SyncStage.wake` entry the instant WorkManager
  invokes the task, before any skip/connect decision — every other log
  entry only appears once real work is attempted, which made "is the OS
  even waking this up on schedule" unanswerable from the log alone.

`device_screen.dart` surfaces `DatabaseHelper.findGaps()` (readings
grouped by consecutive gaps ≥5 min, over the last 6h) directly in the app —
the same kind of gap that was previously only discoverable by opening an
exported session CSV after the fact.

## Auth model

- No self-registration. A one-time **enrollment code** (issued by a
  researcher or the public website consent flow) is required to create an
  account — claiming it also assigns a fresh, server-generated,
  unguessable `patient_id`.
- Tokens: short-lived JWT access token + longer-lived refresh token, stored
  via `flutter_secure_storage`. `server_service.dart`'s upload call attaches
  the access token as a Bearer header; a `401` triggers one refresh-and-retry
  before falling back to prompting re-login.
- No real name, birth year, or sex is collected anywhere in the app — an
  earlier profile-setup screen did, but nothing downstream (the model, the
  export, the UI) actually used that data, so it was removed.

## Platform notes

- Android only — `MainActivity` is `FlutterFragmentActivity` (required by
  `local_auth`'s biometric prompt, not the default `FlutterActivity`).
- iOS is not currently built/tested.
