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
| `debug_screen.dart` | Not currently reachable from any navigation path — leftover dev tool for inserting test DB rows. Safe to delete or wire up, whichever is more useful. |

## Services

| Service | Purpose |
|---|---|
| `auth_service.dart` | Enrollment/login/refresh, token storage via `flutter_secure_storage`. |
| `ble_service.dart` | Scanning, connecting, parsing incoming Bangle.js/T-Watch data, BLE line reassembly (see below). Singleton (`BleService()` factory always returns the same instance). |
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
