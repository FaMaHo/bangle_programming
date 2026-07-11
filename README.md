# PulseWatch AI

**AI Bracelet for Early Detection of Heart Sclerosis**
A wearable system for preventive cardiac monitoring.

Academic project — Faculty of Engineering in Foreign Languages (FILS), NUST Politehnica Bucharest
Authors: Mahmoudzadehosseini FatemehSadat · Daria Gladkykh
Supervisor: Prof. Dr. Ing. Nicolae Goga

---

## Table of Contents

1. [What This System Does](#what-this-system-does)
2. [System Architecture](#system-architecture)
3. [What Is Currently Working](#what-is-currently-working)
4. [Setup Guide](#setup-guide)
5. [Where Things Live](#where-things-live)
6. [Future Research Suggestions](#future-research-suggestions)

---

## What This System Does

PulseWatch AI continuously monitors heart rate and motion data through a Bangle.js 2 smartwatch, transfers that data to a Flutter mobile app via Bluetooth, and uploads it to a research server for cardiovascular analysis. The goal is early detection of heart sclerosis (cardiosclerosis) — a condition that advances silently for years before clinical symptoms appear.

The AI model (XGBoost, trained on 10.4 million rows from 7 public datasets) runs on the researcher's machine and produces a 0–1 risk probability from 48-hour recordings. A lighter version of the same feature pipeline also runs on-device in the app for a live risk estimate.

---

## System Architecture

```
Bangle.js 2 Watch
  └─ PPG (HRM) + Accelerometer, continuous while recording
  └─ Buffers CSV in flash memory, saved every 5 minutes
  └─ Streams live data over BLE (Nordic UART), batched every 15s
        │
        ▼ Bluetooth Low Energy
Flutter Mobile App (Android — iOS not yet supported, see below)
  └─ Account: enrollment code (one-time) or username/password login
  └─ Receives live BLE data, stores in local SQLite
  └─ Computes an on-device risk estimate from rolling HRV features
  └─ Shows Home dashboard, Insights, Device, Upload, Settings screens
  └─ Optional biometric/PIN app-lock
  └─ Exports anonymized CSV (last 48 hours) and uploads over HTTPS
        │
        ▼ HTTPS (JWT-authenticated) — works over any internet connection
Flask Backend — always-on VPS at pulsana.org
  └─ Patient/researcher accounts (SQLite, password-hashed)
  └─ Stores CSVs in patient_data/{patient_id}/{session_id}/
  └─ Website: patient consent + enrollment-code signup, APK download,
     researcher login portal (list patients, generate codes, download data)
        │
        ▼ Manual step (researcher)
XGBoost AI Model
  └─ Feature extraction (HRV time/frequency-domain, PPG morphology, activity, nocturnal)
  └─ Outputs risk probability + Markdown report
```

The backend used to run on a researcher's laptop, reachable only over the same WiFi network as the patient, with a QR code to pair the app to whatever IP the laptop had that day. It's now a normal always-on server at a fixed domain — patients don't need to be anywhere near the researcher, and there's no pairing dance.

---

## What Is Currently Working

### Bangle.js 2 Firmware (`bangle/`)

- Background heart rate monitoring using the onboard HRM sensor, including real beat-to-beat RR intervals (not just averaged BPM)
- 3-axis accelerometer recording (Kionix KX022)
- Data buffered in flash as timestamped CSV files (`pw*.csv`), saved every 5 minutes
- Live data streamed over BLE (Nordic UART), batched into one transmission every 15 seconds instead of one per sample — cuts radio wake-ups roughly 15x for battery life, with no loss of data fidelity (flash still captures every sample)
- Auto-starts recording on watch boot if enabled in settings
- Control menu in the watch launcher: toggle recording, view status, delete data
- Green dot widget in top-right corner shows recording is active
- Data format: `timestamp, bpm, rr_interval_ms, confidence, accel_x, accel_y, accel_z`

See [`bangle/ARCHITECTURE.md`](bangle/ARCHITECTURE.md) for details.

### Flutter Mobile App (`pulsewatch_app/`)

**Screens:**

- **Home** — dashboard: watch connection status (tap to go connect it), 48-hour data-collection progress, live heart rate with real signal-quality percentage from the watch's HRM confidence, cardiac risk gauge, and a nudge if there's unsynced data waiting to be uploaded
- **Insights** — weekly day-by-day data presence, 7-day heart rate stats plus average signal quality, days-recorded progress
- **Device** — BLE scan and connect to Bangle.js 2 or T-Watch S3 Plus; Bangle.js always appears first; auto-starts recording on connection; real signal-quality reading (not a made-up score)
- **Upload** — anonymized data export and upload to the research server, with a consent screen before every upload
- **Settings** — account info, log out, biometric/PIN app-lock toggle (separated out from the Upload page, which used to hold all of this)

**Accounts & Privacy:**

- No self-registration: a researcher (or the website's consent flow) issues a one-time enrollment code, which also mints a fresh, unguessable `patient_id` (e.g. `P-9ADF8CE5`) server-side
- Patient picks a username and password once, then logs in normally after that
- No real name, birth year, or biological sex is collected anywhere anymore — the old profile-setup screen that did this was removed since nothing downstream (the model, the export) actually used that data
- Tokens stored via `flutter_secure_storage` (Keychain/Keystore-backed), not plain SharedPreferences
- Optional biometric/device-PIN app-lock, re-locks whenever the app leaves the foreground

**BLE Integration:**

- Connects to Bangle.js 2 via Nordic UART Service; reassembles data that arrives split across multiple BLE packets before parsing it (a single CSV line is often longer than one packet)
- Sends `require("pulsewatch").start()` command on connection to auto-start recording
- Also supports T-Watch S3 Plus via a custom BLE service
- Bangle.js automatically sorted to top of scan results list

**Data Export & Upload:**

- Exports last 48 hours as anonymized CSV: `timestamp, hr_bpm, rr_intervals_ms, accel_x, accel_y, accel_z`
- `device_id` and `confidence` columns intentionally excluded from export
- Consent bottom sheet before every upload — shows exactly what will be sent, requires explicit checkbox confirmation
- Uploads authenticate with a JWT bearer token (not a client-supplied patient ID header, which could previously be spoofed)

See [`pulsewatch_app/ARCHITECTURE.md`](pulsewatch_app/ARCHITECTURE.md) for details.

### Flask Backend + Website (`pulsewatch_backend/`)

Deployed on a DigitalOcean VPS at **pulsana.org**, behind nginx with a Let's Encrypt TLS certificate, running under systemd (gunicorn).

**API (used by the app):**
- `/auth/claim`, `/auth/login`, `/auth/refresh`, `/auth/enroll` — accounts and JWT tokens
- `/upload`, `/upload_chunk`, `/upload_recorder_log` — receive CSV data (patient identity comes from the verified token, never a client-supplied header)
- `/patient/{id}/sessions`, `/patient/{id}/session/{id}/data` — read back a patient's data (patient can only read their own; researcher role can read any)
- `/health` — health check

**Website (server-rendered, no separate frontend framework):**
- `/` — landing page
- `/download` — consent/terms page → issues a one-time enrollment code → links to the Android APK
- `/researcher/login`, `/researcher/dashboard`, `/researcher/patient/{id}` — session-cookie-based researcher portal: list patients, generate enrollment codes, download session CSVs

See [`pulsewatch_backend/ARCHITECTURE.md`](pulsewatch_backend/ARCHITECTURE.md) for details, including how to run it locally and how it's deployed.

### AI Model (separate — not in this repo)

- Binary XGBoost classifier (n_estimators=200, max_depth=6)
- Trained on 7 public datasets: CAST RR, MIT-BIH NSR, MIT-BIH LTDB, SCD Holter, TROIKA, GalaxyPPG (10.4M rows total)
- Performance: Accuracy 0.85, AUC 0.91, Brier Score 0.082, Specificity 0.87
- Extracts 20 features across 5-minute windows: HRV time-domain, HRV frequency-domain, PPG morphology, activity, nocturnal
- Outputs a 0–1 risk probability and Markdown report
- Training/evaluation/conversion scripts for this model live in `models/`, separate from the app's on-device ONNX copy in `pulsewatch_app/assets/models/`

---

## Setup Guide

### Prerequisites

- macOS, Windows, or Linux (for app/firmware development)
- Flutter SDK 3.x
- Android phone or emulator (tested on Samsung S908B) — **iOS is not currently supported**, see below
- Bangle.js 2 smartwatch
- Python 3.10+ and [`uv`](https://docs.astral.sh/uv/) (only needed if you're running your own backend instead of using the hosted one)

> **iOS:** the app currently only targets Android. Building for iOS would additionally
> require Xcode (macOS only) and hasn't been set up/tested.

### 1. Clone the Repository

```bash
git clone https://github.com/FaMaHo/bangle_programming.git
cd bangle_programming
```

### 2. Set Up the Watch Firmware

1. Open [Bangle.js App Loader](https://banglejs.com/apps) in Chrome
2. Connect your Bangle.js 2
3. Upload these files from `bangle/`:
   - `lib.js` → save as `pulsewatch` (no extension)
   - `app.js` → save as `pulsewatch.app.js`
   - `boot.js` → save as `pulsewatch.boot.js`
   - `widget.js` → save as `pulsewatch.wid.js`
4. Or use the Web IDE and upload `metadata.json` directly via the App Loader
5. On the watch, go to Settings → enable recording via the PulseWatch menu
6. The green dot widget confirms recording is active

### 3. Set Up the Flutter App

```bash
cd pulsewatch_app
flutter pub get
flutter run
```

The app talks to the production backend at `https://pulsana.org` by default — no server setup needed to try it. To point it at your own backend instead, change `_defaultServerUrl` in `lib/services/server_service.dart`, or set the server URL from the Upload screen at runtime.

**First launch:**
- You'll be asked for an enrollment code (get one from `https://pulsana.org/download`, or have a researcher generate one from the portal) plus a username and password you choose
- Returning users just log in with that username/password

**Connect the watch:**
1. Go to the **Device** tab → **Scan for Devices**
2. Bangle.js appears at the top with a green border → **Connect**
3. Recording starts automatically

### 4. Running Your Own Backend (optional)

Only needed if you don't want to use the hosted `pulsana.org` instance — e.g. for local development.

```bash
cd pulsewatch_backend
uv venv
# macOS/Linux: source .venv/bin/activate   |   Windows: .venv\Scripts\activate
uv pip install -r requirements.txt
python app.py
```

Then create a researcher account with `python create_admin.py`, and see [`pulsewatch_backend/ARCHITECTURE.md`](pulsewatch_backend/ARCHITECTURE.md) for the full route list, the auth model, and how the production deployment (nginx + systemd + Let's Encrypt) is set up.

### 5. Collecting and Downloading Research Data

As a researcher, log into `https://pulsana.org/researcher/login`, or use the API directly:

```bash
curl -H "Authorization: Bearer <your_access_token>" https://pulsana.org/patient/P-XXXXXXXX/sessions
curl -H "Authorization: Bearer <your_access_token>" https://pulsana.org/patient/P-XXXXXXXX/session/<session_id>/data
```

---

## Where Things Live

| Folder | What's in it | Details |
|---|---|---|
| `bangle/` | Bangle.js 2 firmware (Espruino/JS) | [`ARCHITECTURE.md`](bangle/ARCHITECTURE.md) |
| `pulsewatch_app/` | Flutter mobile app | [`ARCHITECTURE.md`](pulsewatch_app/ARCHITECTURE.md) |
| `pulsewatch_backend/` | Flask API + website, deployed to `pulsana.org` | [`ARCHITECTURE.md`](pulsewatch_backend/ARCHITECTURE.md) |
| `models/` | AI model training/evaluation/conversion scripts (XGBoost + ONNX/TFLite export) | — |
| `firmware/` | T-Watch S3 Plus firmware (secondary/experimental device) | — |
| `docs/` | Historical design docs, hardware reference PDFs, deployment notes | — |
| `server/` | Early prototype backend, superseded by `pulsewatch_backend/` — kept for reference, not active | — |

---

## Future Research Suggestions

**PPG morphology features**
Two of the model's features (`systolic_upslope`, `diastolic_decay` — a combined ~14% of feature importance) need raw PPG waveform samples, which the current firmware doesn't expose (only derived BPM/confidence/RR). Getting real values here instead of training-set-mean placeholders would need firmware changes to stream raw PPG, which the Bangle.js HRM API may or may not support — worth investigating.

**HRM duty-cycling for battery**
The HRM sensor currently runs continuously while recording (needed for real HRV). Duty-cycling it (e.g. 10 minutes on, out of every 30) could meaningfully extend battery life, but trades off against data continuity and overnight/nocturnal-feature coverage — a product decision, not just an engineering one.

**iOS support**
The app is Android-only today. Bringing up iOS needs Xcode/macOS for builds, an Apple Developer account for any real distribution (TestFlight or App Store), and testing the BLE/biometric-lock/secure-storage code paths on iOS.

**Play Store distribution**
Currently distributed as a direct APK download (with the "unknown sources" install warning that implies). Moving to the Play Store would need a proper `applicationId` (currently the Flutter default `com.example.pulsewatch_app`), a Play Console account, and a release/versioning workflow.

**Real informed-consent text**
The website's `/download` consent page ships with placeholder text — needs the actual IRB-approved consent language before real participants use it.

**On-device inference**
Run the XGBoost model (converted to TensorFlow Lite Micro) directly on the Bangle.js 2, for a risk indicator on the watch face itself. Requires significant model compression and TFLite Micro integration with Espruino.

**Database encryption**
Local SQLite storage on the phone is currently unencrypted (`sqflite`, not `sqflite_sqlcipher`). Would need adding SQLCipher to match the privacy guarantees described in the project's write-up.

**Prospective clinical validation**
The current proof-of-concept used simulated/pilot data. The next scientific step is collecting data from participants with confirmed clinical diagnoses, validated by a cardiologist, to quantify how well the system performs on real Bangle.js PPG signals (which differ from the ECG-derived training data).

**Multi-class severity grading**
The current model is binary (Healthy / Cardiac). Extending to multi-class would allow Low / Medium / High / Critical risk levels, giving more actionable output for clinical screening.

**Domain adaptation**
The model was trained on ECG-derived RR intervals and wrist PPG from other devices. Bangle.js 2 PPG signals have different noise characteristics. Fine-tuning on a small amount of labeled Bangle.js data would reduce this domain shift and likely improve accuracy substantially.

**Automated report delivery**
Currently the researcher runs the inference script manually and reads the Markdown output. A future version could email or push the risk report to the participant or their clinician automatically after each 48-hour session completes.
