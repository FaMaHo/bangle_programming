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
5. [Next Steps (Planned)](#next-steps-planned)
6. [Future Research Suggestions](#future-research-suggestions)

---

## What This System Does

PulseWatch AI continuously monitors heart rate and motion data through a Bangle.js 2 smartwatch, transfers that data to a Flutter mobile app via Bluetooth, and uploads it to a research server for cardiovascular analysis. The goal is early detection of heart sclerosis (cardiosclerosis) — a condition that advances silently for years before clinical symptoms appear.

The AI model (XGBoost, trained on 10.4 million rows from 7 public datasets) runs on the researcher's machine and produces a 0–1 risk probability from 48-hour recordings.

---

## System Architecture

```
Bangle.js 2 Watch
  └─ PPG + Accelerometer at ~1 Hz
  └─ Buffers CSV in flash memory
  └─ Streams live data via BLE Nordic UART
        │
        ▼ Bluetooth Low Energy
Flutter Mobile App (Android / iOS)
  └─ Receives and stores data in SQLite
  └─ Shows heart rate stats on Today screen
  └─ Exports anonymized CSV (last 48 hours)
  └─ Uploads to research server via HTTP
        │
        ▼ HTTP POST (same WiFi network)
Flask Backend Server (researcher's laptop)
  └─ Stores CSVs in patient_data/{patient_id}/{session_id}/
  └─ Serves QR code page for easy connection
  └─ Health check endpoint
        │
        ▼ Manual step (researcher)
XGBoost AI Model
  └─ Feature extraction (HRV, PPG morphology, activity, nocturnal)
  └─ Outputs risk probability + Markdown report
```

---

## What Is Currently Working

### Bangle.js 2 Firmware (`bangle/`)

- Background heart rate monitoring using the onboard HRM sensor
- 3-axis accelerometer recording (Kionix KX022)
- Data buffered in flash as timestamped CSV files (`pw*.csv`)
- Files saved every 5 minutes automatically
- Live data streamed over BLE Nordic UART service on each HRM event
- Auto-starts recording on watch boot if enabled in settings
- Control menu in the watch launcher: toggle recording, view status, delete data
- Green dot widget in top-right corner shows recording is active
- Data format: `timestamp, bpm, confidence, accel_x, accel_y, accel_z`

### Flutter Mobile App (`pulsewatch_app/`)

**Screens:**

- **Today** — shows today's heart rate stats (min, avg, max), total readings, signal score, and live connection status when watch is paired
- **Insights** — weekly day-by-day data presence indicator, 7-day heart rate averages, data quality progress bar
- **Device** — BLE scan and connect to Bangle.js 2 or T-Watch S3 Plus; Bangle.js always appears first in scan results; auto-starts recording on connection; shows "Data streaming automatically" when connected
- **Upload** — anonymized data export and upload to research server

**Profile & Privacy:**

- First-launch profile setup (name, birth year, biological sex)
- Anonymous patient ID generated from profile (format: `P-XXXX-YYYY`) — real name is never exported or transmitted
- Profile stored locally only

**BLE Integration:**

- Connects to Bangle.js 2 via Nordic UART Service
- Receives live CSV lines from watch and stores directly to SQLite
- Sends `require("pulsewatch").start()` command on connection to auto-start recording
- Also supports T-Watch S3 Plus via custom BLE service
- Bangle.js automatically sorted to top of scan results list

**Data Export & Upload:**

- Exports last 48 hours as anonymized CSV: `timestamp, hr_bpm, accel_x, accel_y, accel_z`
- `device_id` and `confidence` columns intentionally excluded from export
- Consent bottom sheet before every upload — shows exactly what will be sent, requires explicit checkbox confirmation
- QR code scanning to connect to server — no manual IP typing required
- Auto-tests connection immediately after QR scan
- Sends `X-Patient-ID` and `X-Session-ID` headers; no `X-Device-ID`

### Flask Backend Server (`pulsewatch_backend/`)

- `/upload` — receives CSV, saves to `patient_data/{patient_id}/{session_id}/`
- `/health` — health check (used by app to test connection)
- `/qr` — serves an HTML page with a scannable QR code encoding the server's WiFi IP and port; researcher opens this in a browser, patient scans it with the app
- `/patient/{id}/sessions` — lists all sessions for a patient
- `/patient/{id}/session/{id}/data` — returns combined CSV for a session
- Runs in Docker via `docker-compose`

### AI Model (separate — not in this repo)

- Binary XGBoost classifier (n_estimators=200, max_depth=6)
- Trained on 7 public datasets: CAST RR, MIT-BIH NSR, MIT-BIH LTDB, SCD Holter, TROIKA, GalaxyPPG (10.4M rows total)
- Performance: Accuracy 0.85, AUC 0.91, Brier Score 0.082, Specificity 0.87
- Extracts 20 features across 5-minute windows: HRV time-domain, HRV frequency-domain, PPG morphology, activity, nocturnal
- Outputs a 0–1 risk probability and Markdown report

---

## Setup Guide

### Prerequisites

- macOS or Ubuntu laptop (the research server machine)
- Python 3.10+
- Docker Desktop
- Flutter SDK 3.x
- Android phone (tested on Samsung S908B) or iOS device
- Bangle.js 2 smartwatch

---

### 1. Clone the Repository

```bash
git clone https://github.com/FaMaHo/bangle_programming.git
cd bangle_programming
```

---

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

---

### 3. Set Up the Backend Server

**Install Python dependencies:**

```bash
cd pulsewatch_backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

**Build and start with Docker:**

```bash
# Get your laptop's WiFi IP first
python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()"

# Start with your real IP injected (replace 192.168.x.x with your actual IP)
HOST_IP=192.168.x.x docker-compose up -d
```

**Or run without Docker (simpler for testing):**

```bash
cd pulsewatch_backend
source .venv/bin/activate
python3 app.py
```

**Verify it works:**

```bash
curl http://localhost:5001/health
# Should return: {"status": "healthy", ...}
```

**Generate the QR code for patients:**

Open in your browser: `http://localhost:5001/qr`

This page shows a QR code with your laptop's WiFi IP encoded. Show it to the patient — they scan it from the app.

> **Important:** Your laptop and the patient's phone must be on the **same WiFi network**. Personal hotspot does not work.

---

### 4. Set Up the Flutter App

**Install dependencies:**

```bash
cd pulsewatch_app
flutter pub get
```

**Run on your Android device:**

```bash
flutter run
```

**First launch:**

- The app will open a profile setup screen
- Enter name, birth year, and biological sex
- An anonymous research ID is generated (e.g. `P-A3F2-1990`) — this is what appears in uploaded data, never the real name

**Connect to the server:**

1. Go to the **Upload** tab
2. Tap the QR scan icon (green camera icon next to the URL field)
3. Scan the QR code from `http://localhost:5001/qr`
4. The app connects automatically

**Connect to the watch:**

1. Go to the **Device** tab
2. Tap **Scan for Devices**
3. Bangle.js will appear at the top of the list with a green border
4. Tap **Connect** — the watch starts recording automatically

---

### 5. Starting the Server After Laptop Restart

Your WiFi IP may change each time you reconnect. Always start the server with the current IP:

```bash
cd pulsewatch_backend
source .venv/bin/activate

# Option A: Docker
HOST_IP=$(python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()") docker-compose up -d

# Option B: Direct Python (simpler)
python3 app.py
```

Then refresh `http://localhost:5001/qr` in your browser — it will show the new QR with the updated IP.

---

### 6. Collecting and Downloading Research Data

Data is stored in `pulsewatch_backend/patient_data/{patient_id}/{session_id}/`.

To list all sessions for a patient:
```bash
curl http://localhost:5001/patient/P-A3F2-1990/sessions
```

To download combined CSV for a session:
```bash
curl http://localhost:5001/patient/P-A3F2-1990/session/session-xxx/data
```

---

## Next Steps (Planned)

### Auto-send data on app resume
Instead of requiring the user to manually tap "Export & Upload", the app will silently upload whenever it is opened, if more than 6 hours have passed since the last upload and the server URL is configured. This requires no background permissions and works reliably on both Android and iOS.

Files to change: `main.dart`, `server_service.dart`, `server_screen.dart`

### Manager dashboard (web UI)
A password-protected web page served directly from Flask at `/dashboard`. Shows a table of all patients, their sessions, record counts, and last upload time. Each row has a Download CSV button. Login with a hardcoded password (`admin1234`). No new framework needed — pure HTML served inline from Flask.

Files to change: `app.py` only

### `start_server.sh` helper script
A one-line shell script at the repo root that detects the current WiFi IP and starts the server with the correct `HOST_IP` injected. Saves the step of running the Python IP command manually every time.

---

## Future Research Suggestions

**On-device inference**
Run the XGBoost model (converted to TensorFlow Lite Micro) directly on the Bangle.js 2. This would give patients a risk indicator on the watch face without needing to export data to a laptop. Requires significant model compression and TFLite Micro integration with Espruino.

**RR interval collection**
The current firmware collects BPM (averaged heart rate) rather than raw RR intervals (beat-to-beat timing). Switching to `Bangle.setHRMPower(1)` with raw PPG processing would give true RR intervals, which are the foundation of all HRV metrics. This would make the HRV features computed in the app and AI model substantially more accurate.

**Database encryption**
The article describes encrypted SQLite storage. The current implementation uses plain `sqflite`. Adding SQLCipher via the `sqflite_sqlcipher` package would make the local database match the privacy guarantees described in the paper.

**HRV computation in the app**
Currently the app shows min/avg/max heart rate. The article describes computing RMSSD, SDNN, pNN50, and LF/HF ratio from 5-minute windows in the app itself. Adding this would make the Insights screen clinically meaningful and remove the dependency on the researcher running the AI model for basic feedback.

**Prospective clinical validation**
The current proof-of-concept used simulated data. The next scientific step is collecting data from participants with confirmed clinical diagnoses, validated by a cardiologist, to quantify how well the system performs on real Bangle.js PPG signals (which differ from the ECG-derived training data).

**Multi-class severity grading**
The current model is binary (Healthy / Cardiac). Extending to multi-class would allow Low / Medium / High / Critical risk levels, giving more actionable output for clinical screening.

**Domain adaptation**
The model was trained on ECG-derived RR intervals and wrist PPG from other devices. Bangle.js 2 PPG signals have different noise characteristics. Fine-tuning on a small amount of labeled Bangle.js data would reduce this domain shift and likely improve accuracy substantially.

**Automated report delivery**
Currently the researcher runs the inference script manually and reads the Markdown output. A future version could email or push the risk report to the participant or their clinician automatically after each 48-hour session completes.