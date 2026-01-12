# PulseWatch AI — System Design Decisions

**Document Created:** November 2024  
**Status:** Active Development  
**Purpose:** Reference document for all system architecture and design decisions

---

## Project Overview

**Main Objective:** Develop an AI-powered system that detects early signs of heart sclerosis (myocardial fibrosis) using continuous, non-invasive physiological data from smart wearable devices.

**Current Phase:** Transitioning from Phase 1 (Foundation AI Model) to Phase 2 (Motion Artifact Handling) + Hardware/App Development

**Pilot Study Location:** China (hospital access via collaborator)

---

## Hardware Strategy

### Device Roles

| Device | Role | Status |
|--------|------|--------|
| **Bangle.js 2** | Primary pilot device | Shipping, waiting for arrival |
| **T-Watch S3 Plus + MAX30102** | Development & backup device | In hand, requires modification |

### Bangle.js 2 (Primary)

- Built-in PPG heart rate sensor
- Built-in accelerometer
- No wiring required — reliable for shipping to China
- Bluetooth LE only (no WiFi) — requires phone app for data relay
- Battery: up to 4 weeks standby

### T-Watch S3 Plus + MAX30102 (Backup)

**Hardware Challenge:** No externally accessible GPIO pins. Requires opening the case to access I2C bus.

**Internal Wiring Required:**

| MAX30102 Pin | T-Watch Connection |
|--------------|-------------------|
| VIN | 3.3V (internal) |
| GND | GND (internal) |
| SDA | GPIO 10 (internal I2C bus) |
| SCL | GPIO 11 (internal I2C bus) |
| INT | Any available GPIO (optional) |

**I2C Address:** MAX30102 uses 0x57 — no conflict with existing devices (BMA423: 0x19, AXP2101: 0x34, PCF8563: 0x51, DRV2605: 0x5A)

**Assembly Requirements:**
- Open watch case carefully
- Solder 4 thin wires to internal pads
- Route wires out of case with strain relief (hot glue/epoxy)
- Mount MAX30102 in wrist-facing position with consistent skin contact
- Test extensively before any deployment

**Storage Limitation:** 16MB flash total, ~8-10MB available for data after firmware

---

## Data Collection Strategy

### Recording Mode: Hybrid Triggered

Three-tier recording approach balancing data richness with battery/storage constraints:

| Mode | Sample Rate | When Active | Purpose |
|------|-------------|-------------|---------|
| **Baseline** | 10 Hz PPG + ACC | Always | Continuous coverage, low power |
| **High-Fidelity Windows** | 50 Hz | 2 min every 30 min (scheduled) | Guaranteed training data |
| **Triggered Capture** | 50 Hz | When anomaly detected | Capture interesting events |
| **Manual Capture** | 50 Hz | Patient presses button | Patient-reported events |

### Anomaly Triggers

| Trigger | Threshold | Capture Duration |
|---------|-----------|------------------|
| HR too low | < 50 BPM | 60 seconds (30 before, 30 after) |
| HR too high | > 120 BPM | 60 seconds |
| Sudden HR change | ±30 BPM within 1 minute | 60 seconds |
| Poor signal quality | Quality score < 0.5 for >30s | 30 seconds when quality returns |
| No movement + elevated HR | ACC still, HR > 100 | 120 seconds |
| Manual trigger | Patient button press | 5 minutes |

### Estimated Data Volume

| Component | Size per Day |
|-----------|--------------|
| Baseline summaries (24h) | ~5-10 MB |
| High-fidelity windows (48 × 2min) | ~200 MB |
| Triggered captures (estimated) | ~50-100 MB |
| **Total** | **~300-400 MB/day** |

### On-Watch Storage Strategy

Due to limited flash (~8-10 MB available):

- Store HRV summaries (every 30 seconds): ~50 KB/hour
- Store continuous HR (1 Hz): ~15 KB/hour
- Store last 10 triggered raw windows: ~5 MB
- Store activity classifications: ~10 KB/hour

**Buffer Capacity:** ~8-10 hours of summaries + triggered windows

**Sync Requirement:** Phone sync every few hours recommended

---

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    PATIENT WEARS                        │
│                                                         │
│   Bangle.js 2              OR         T-Watch S3 Plus   │
│   (Primary)                           (Backup)          │
│   Built-in PPG                        + MAX30102        │
│                                                         │
└────────────────┬────────────────────────┬───────────────┘
                 │ BLE                    │ BLE
                 └───────────┬────────────┘
                             │
                             ▼
              ┌──────────────────────────┐
              │      Patient's Phone     │
              │      (Flutter App)       │
              │                          │
              │  - Auto BLE connection   │
              │  - Local SQLite storage  │
              │  - Simple patient UI     │
              │  - Background sync       │
              └──────────────┬───────────┘
                             │ WiFi (when available)
                             ▼
              ┌──────────────────────────┐
              │        Backend           │
              │     (TBD - see below)    │
              └──────────────┬───────────┘
                             │
                             ▼
              ┌──────────────────────────┐
              │     Web Dashboard        │
              │  (Remote monitoring)     │
              └──────────────────────────┘
```

---

## Phone Proximity & Sync Behavior

### Watch Behavior
- Continuously records data to internal buffer
- Auto-syncs when phone is in BLE range (~10 meters)
- Shows "last sync: X minutes ago" on display
- Operates independently — doesn't require constant phone connection

### App Behavior
- Runs in background
- Auto-connects when watch detected
- Downloads buffered data automatically
- Shows warning if no sync for >2 hours
- Stores all data locally in SQLite
- Syncs to backend when WiFi available (backend added later)

---

## Watch Interface Design

### Navigation Structure

- **Swipe Left/Right:** Navigate between main pages (3 pages)
- **Swipe Down from Top:** Quick settings / pull-down menu
- **Tap on Status Icons:** Open relevant screens (e.g., tap red connection icon → pairing screen)

---

### Page 1: Main Watch Face

```
┌────────────────────────┐
│ ⚠️        🔗 50% 🔋   │  ← Status bar
│                        │
│                        │
│        10:09           │  ← Time (large, centered)
│                        │
│        ❤️ 72           │  ← Heart rate
│                        │
│                        │
└────────────────────────┘
```

**Status Bar Elements:**
- **⚠️ Warning icon (left):** Only visible when there are connection or recording issues. Hidden when everything is normal.
- **🔗 Connection icon:** Green when paired to phone app, Red when not connected. Tapping opens the connection/pairing screen.
- **🔋 Battery:** Shows percentage and battery icon.

---

### Page 2: Heart Monitor + Manual Capture

```
┌────────────────────────┐
│      Heart Rate        │
│                        │
│    ❤️ 72 BPM          │
│    ▁▂▃▂▁▂▄▃▂▁         │  ← Mini live graph
│                        │
│    Today: 58-89 BPM    │  ← Daily range
│    Avg: 68 BPM         │  ← Daily average
│                        │
│  [ 🫀 I Feel Something ]│  ← Manual capture button
└────────────────────────┘
```

**Manual Capture Button:**
- Triggers 5-minute high-fidelity recording (50 Hz)
- Visual feedback when pressed (haptic + screen confirmation)
- For patients to capture when they feel symptoms

---

### Page 3: Today's Summary

```
┌────────────────────────┐
│       Today            │
│                        │
│   ⏱️ Recording         │
│      5h 23m            │  ← Total recording time today
│                        │
│   📊 Events            │
│      2 captured        │  ← Anomalies + manual captures
│                        │
│   📶 Last Sync         │
│      12 min ago        │  ← Last successful sync to phone
└────────────────────────┘
```

---

### Pull-Down Menu (Swipe from Top Edge)

```
┌────────────────────────┐
│      Quick Settings    │
│                        │
│   🔗 Connected         │  ← Tap to open pairing screen
│   📱 PulseWatch App    │
│                        │
│   🔋 50%   ☀️ Bright   │  ← Battery, brightness toggle
│                        │
│   [ 🔄 Sync Now ]      │  ← Force manual sync
│                        │
└────────────────────────┘
```

---

### Connection/Pairing Screen

Accessed via: Tap red connection icon OR tap connection status in pull-down menu

```
┌────────────────────────┐
│      Connect           │
│                        │
│   Status: Searching... │
│                        │
│   Device ID:           │
│   PW-A3F2              │  ← Unique watch identifier
│                        │
│   Open app on phone    │
│   and tap "Connect"    │
│                        │
└────────────────────────┘
```

When connected:
```
┌────────────────────────┐
│      Connect           │
│                        │
│   ✅ Connected         │
│                        │
│   Device ID:           │
│   PW-A3F2              │
│                        │
│   Phone: Patient's     │
│   iPhone               │
│                        │
│   [ Disconnect ]       │
└────────────────────────┘
```

---

## Mobile App Design

### Framework & Stack

| Component | Technology |
|-----------|------------|
| Framework | Flutter |
| BLE Library | flutter_blue_plus |
| Local Database | SQLite (sqflite) |
| State Management | Provider or Riverpod |
| Language | English (Chinese localization ready to add later) |

---

### App Structure (3 Tabs)

| Tab | Purpose |
|-----|---------|
| **Today** | Live status, current session, quick glance at what's happening now |
| **Insights** | History, calendar view, trends, detailed data exploration |
| **Device** | Connection management, sync status, patient ID assignment |

---

### Color Palette

| Element | Color Code | Use |
|---------|------------|-----|
| Background | #FAF8F5 (Warm off-white) | Main app background |
| Cards | #FFFFFF (White) | Content cards |
| Primary Accent | #7CB686 (Sage green) | Signal score, positive states, buttons |
| Secondary Accent | #E8A598 (Soft coral) | Heart rate, alerts |
| Text Primary | #2D3142 (Dark gray) | Headlines, important text |
| Text Secondary | #6B7280 (Medium gray) | Labels, descriptions |
| Success | #4CAF50 (Green) | Connected, good status |
| Warning | #F59E0B (Amber) | Attention needed |
| Error | #EF5350 (Soft red) | Disconnected, problems |

**Design Philosophy:** Warm and supportive, not clinical or cold. Inspired by premium health apps like Asclepios.

---

### Screen 1: Today (Home)

```
┌─────────────────────────────────────────┐
│ 9:30                         📶  🔋    │
│                                         │
│                                         │
│         ┌─────────────────────┐         │
│         │                     │         │
│         │      🫀  92         │         │
│         │    Signal Score     │         │
│         │                     │         │
│         │   ● Recording       │         │
│         └─────────────────────┘         │
│                                         │
│                                         │
│  ❤️ Heart Rate                          │
│  ┌─────────────────────────────────┐    │
│  │                                 │    │
│  │  72 bpm            ▁▃▅▃▂▄▃▂▁   │    │
│  │  ○ 58 lowest  ○ 89 highest     │    │
│  │                                 │    │
│  └─────────────────────────────────┘    │
│                                         │
│                                         │
│  ┌───────────────┐ ┌───────────────┐    │
│  │    5h 23m     │ │      2        │    │
│  │   ⏱️ Active   │ │  📍 Events    │    │
│  └───────────────┘ └───────────────┘    │
│                                         │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  📶 Last sync: 2 minutes ago    │    │
│  └─────────────────────────────────┘    │
│                                         │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│     ◉          ◯            ◯          │
│   Today     Insights      Device        │
└─────────────────────────────────────────┘
```

**Elements:**
- **Signal Score (prominent):** Large circular indicator showing data collection quality (0-100)
- **Recording indicator:** Shows if watch is actively recording
- **Heart Rate card:** Current BPM with mini sparkline graph and daily range
- **Stats cards:** Recording time and events captured today
- **Sync status:** Last successful sync with watch

---

### Screen 2: Insights (History & Trends)

```
┌─────────────────────────────────────────┐
│ 9:30                         📶  🔋    │
│                                         │
│  Insights                               │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │      November 2024        < >   │    │
│  │  Su  Mo  Tu  We  Th  Fr  Sa     │    │
│  │              ●   ●   ●   ●      │    │
│  │  ●   ●   ●   ●   ●   ●   ●      │    │
│  │  ●   ●   ●   ◉   ○   ○   ○      │    │
│  │  ○   ○   ○   ○   ○   ○   ○      │    │
│  └─────────────────────────────────┘    │
│   ● Recorded   ◉ Today   ○ Future       │
│                                         │
│                                         │
│  Wednesday, Nov 20                      │
│  ┌─────────────────────────────────┐    │
│  │                                 │    │
│  │  Signal: 94%      ⏱️ 5h 23m    │    │
│  │                                 │    │
│  │  ❤️ 68 avg       📍 2 events   │    │
│  │     58-89 range                 │    │
│  │                                 │    │
│  └─────────────────────────────────┘    │
│                                         │
│                                         │
│  Heart Rate Trend (7 days)              │
│  ┌─────────────────────────────────┐    │
│  │     ╭─╮                         │    │
│  │   ╭─╯ ╰─╮ ╭─╮   ╭╮             │    │
│  │  ─╯     ╰─╯ ╰───╯╰─            │    │
│  │  M   T   W   T   F   S   S     │    │
│  └─────────────────────────────────┘    │
│                                         │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│     ◯          ◉            ◯          │
│   Today     Insights      Device        │
└─────────────────────────────────────────┘
```

**Elements:**
- **Calendar view:** Visual indicator of which days have recorded data
- **Day detail card:** Tap any day to see summary (signal quality, recording time, HR stats, events)
- **Trend graph:** 7-day heart rate trend visualization

---

### Screen 3: Device

```
┌─────────────────────────────────────────┐
│ 9:30                         📶  🔋    │
│                                         │
│  Device                                 │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │                                 │    │
│  │        ⌚                       │    │
│  │     Bangle.js 2                 │    │
│  │                                 │    │
│  │     ✅ Connected                │    │
│  │                                 │    │
│  └─────────────────────────────────┘    │
│                                         │
│                                         │
│  Watch Status                           │
│  ┌─────────────────────────────────┐    │
│  │  🔋 Battery         85%         │    │
│  │  📶 Signal          Good        │    │
│  │  📊 Data pending    1.2 MB      │    │
│  └─────────────────────────────────┘    │
│                                         │
│         ┌─────────────────┐             │
│         │    🔄 Sync Now  │             │
│         └─────────────────┘             │
│                                         │
│  Patient ID                             │
│  ┌─────────────────────────────────┐    │
│  │  ID: CN-001                     │    │
│  │  Assigned: Nov 15, 2024         │    │
│  │                                 │    │
│  │  [ Change Patient ]             │    │
│  └─────────────────────────────────┘    │
│                                         │
│                                         │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│     ◯          ◯            ◉          │
│   Today     Insights      Device        │
└─────────────────────────────────────────┘
```

**Elements:**
- **Device card:** Watch model and connection status
- **Watch status:** Battery level, signal quality, pending data to sync
- **Sync button:** Manual sync trigger
- **Patient ID:** Current patient assignment with ability to change

---

### Screen 4: Connect Watch (When Not Connected)

```
┌─────────────────────────────────────────┐
│ 9:30                         📶  🔋    │
│                                         │
│  Connect Watch                          │
│                                         │
│                                         │
│                                         │
│              ⌚                         │
│           Searching...                  │
│                                         │
│                                         │
│                                         │
│  Found Devices                          │
│  ┌─────────────────────────────────┐    │
│  │                                 │    │
│  │  ⌚ Bangle.js A3F2              │    │
│  │     Tap to connect              │    │
│  │                                 │    │
│  ├─────────────────────────────────┤    │
│  │                                 │    │
│  │  ⌚ TWatch B7C1                 │    │
│  │     Tap to connect              │    │
│  │                                 │    │
│  └─────────────────────────────────┘    │
│                                         │
│                                         │
│  Make sure your watch is:               │
│  • Powered on                           │
│  • Bluetooth enabled                    │
│  • Within range                         │
│                                         │
│                                         │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│     ◯          ◯            ◉          │
│   Today     Insights      Device        │
└─────────────────────────────────────────┘
```

---

### Signal Score Explanation

The **Signal Score** (0-100) reflects data collection quality, NOT health predictions. This is intentional for the pilot phase since the AI model is not yet validated for health assessments.

**Signal Score Components:**
| Factor | Weight | Description |
|--------|--------|-------------|
| Recording hours today | 30% | More hours = higher score |
| Signal quality average | 30% | PPG signal clarity |
| Successful syncs | 20% | Data successfully transferred |
| Events captured | 20% | Anomalies + manual captures logged |

**Score Interpretation:**
| Score | Label | Meaning |
|-------|-------|---------|
| 90-100 | Excellent | Great data collection day |
| 75-89 | Good | Solid recording, minor gaps |
| 50-74 | Fair | Some issues, check device fit |
| Below 50 | Poor | Check connection and device positioning |

**Future Evolution:** Once the AI model is validated, this could transition to a health-related score.

---

### Design Principles

1. **One focus per screen** — Today = now, Insights = history, Device = connection
2. **Glanceable** — User understands status within 2 seconds
3. **Warm, not clinical** — Supportive aesthetic, not scary medical feel
4. **Honest metrics** — Signal Score measures data quality, not unvalidated health predictions
5. **Minimal interaction** — Most things happen automatically (auto-connect, auto-sync)
6. **Offline-first** — App works fully without internet, syncs when available

---

### App Architecture

```
┌─────────────────────────────────────────┐
│            Flutter App                  │
├─────────────────────────────────────────┤
│  UI Layer                               │
│  - Today / Insights / Device screens    │
│  - Warm, card-based design              │
│  - Simple, clear, minimal interaction   │
├─────────────────────────────────────────┤
│  BLE Layer                              │
│  - Device scanning & discovery          │
│  - Connection management                │
│  - Auto-reconnect logic                 │
│  - Data streaming from watch            │
├─────────────────────────────────────────┤
│  Data Layer                             │
│  - SQLite local storage                 │
│  - Data parsing and validation          │
│  - Signal Score calculation             │
├─────────────────────────────────────────┤
│  Processing Layer (Future)              │
│  - Placeholder for on-device ML         │
│  - TensorFlow Lite integration          │
├─────────────────────────────────────────┤
│  Sync Layer (Placeholder)               │
│  - Backend API calls                    │
│  - To be implemented when backend ready │
└─────────────────────────────────────────┘
```

---

## Backend (Deferred)

### Status
Awaiting professor confirmation on budget/hosting options.

### Candidate Options

| Option | Cost | China Access | Notes |
|--------|------|--------------|-------|
| Oracle Cloud Free Tier | $0 | Variable | Try first |
| Vultr/DigitalOcean Singapore | ~$5/month | Often works | Good fallback |
| Alibaba Cloud Hong Kong | ~$12-15/month | Guaranteed | Most reliable |
| Tencent Cloud | ~$8-15/month | Guaranteed | Alternative to Alibaba |

### Requirements (When Implemented)

- Must be accessible from both China (no VPN) and Romania
- REST API for data upload
- PostgreSQL database for structured data
- File storage for raw data dumps
- Simple web dashboard for remote monitoring

### App Design for Backend Flexibility

The Flutter app is designed to be backend-agnostic:
- All data stored locally first
- Sync layer is a separate module
- Can swap backend URL/implementation without touching other code
- Works fully offline if backend unavailable

---

## Standardized Data Format

Both watches will send data in identical format for unified processing:

### Session Metadata
```json
{
  "session_id": "uuid-v4",
  "device_type": "bangle_js_2" | "twatch_s3",
  "device_id": "mac_address",
  "patient_id": "assigned_id",
  "start_time": "ISO8601",
  "end_time": "ISO8601",
  "firmware_version": "1.0.0"
}
```

### Summary Data (Every 30 seconds)
```json
{
  "session_id": "uuid",
  "timestamp": 1700000000000,
  "type": "summary",
  "data": {
    "hr_mean": 72,
    "hr_min": 68,
    "hr_max": 78,
    "hrv_sdnn": 45.2,
    "hrv_rmssd": 38.1,
    "activity_level": "sedentary" | "light" | "moderate" | "vigorous",
    "signal_quality": 0.85,
    "battery_level": 85
  }
}
```

### Raw Data Window (Triggered/Scheduled)
```json
{
  "session_id": "uuid",
  "timestamp": 1700000000000,
  "type": "raw_window",
  "trigger": "scheduled" | "anomaly_hr_high" | "anomaly_hr_low" | "manual" | ...,
  "duration_seconds": 30,
  "sample_rate": 50,
  "data": {
    "ppg_green": [array of values],
    "ppg_red": [array of values],
    "ppg_ir": [array of values],
    "acc_x": [array of values],
    "acc_y": [array of values],
    "acc_z": [array of values]
  }
}
```

### Event Marker
```json
{
  "session_id": "uuid",
  "timestamp": 1700000000000,
  "type": "event",
  "event_type": "anomaly_detected" | "manual_capture" | "sync_completed" | ...,
  "details": {
    "reason": "hr_above_threshold",
    "value": 135,
    "threshold": 120
  }
}
```

---

## AI Evolution Roadmap

### Stage 1: Data Collection (Current)
- Watch captures raw + summaries
- Phone stores everything locally
- Server aggregates all patient data (when ready)
- Team trains models offline

### Stage 2: Validated Model
- Watch behavior unchanged
- Phone runs inference on incoming data
- Flags anomalies for review
- Server receives flagged events + samples (not everything)
- Model refined with edge cases

### Stage 3: On-Device Intelligence
- Watch runs TinyML model directly
- Only sends alerts + daily summaries
- Phone displays results
- Server monitors population-level patterns

### Stage 4: Continuous Learning (Future)
- Watch flags uncertain predictions
- Uncertain cases uploaded for review
- Model retrained with new data
- Updates pushed to watches

---

## Development Priority

### Immediate (While Waiting for Bangle.js 2)

1. **Flutter App Skeleton**
   - Project setup with proper architecture
   - BLE scanning and connection
   - Local SQLite database
   - Basic UI screens

2. **T-Watch Experimentation**
   - Open case, identify solder points
   - Test MAX30102 connection
   - Basic firmware for PPG reading
   - BLE data transmission

### When Bangle.js 2 Arrives

3. **Bangle.js 2 Watch App**
   - JavaScript app for Espruino
   - PPG + accelerometer recording
   - BLE transmission protocol
   - User interface

### After Backend Confirmation

4. **Backend Implementation**
   - API setup on chosen platform
   - Database schema
   - Sync integration in Flutter app
   - Web dashboard

---

## China Deployment Checklist

Before shipping to China:

- [ ] Bangle.js 2 fully tested for 48+ hours continuous wear
- [ ] Watch app stable with auto-recovery from errors
- [ ] Flutter app tested on both iOS and Android
- [ ] App works fully offline (no backend dependency)
- [ ] Chinese language added to app (if time permits)
- [ ] Simple pictorial user guide created
- [ ] Troubleshooting guide with common issues
- [ ] Backup devices if budget allows
- [ ] Backend accessible from China confirmed (when ready)

---

## Open Questions

1. **Patient count** — How many patients in pilot? (Affects device quantity needed)
2. **Backend budget** — Professor confirmation pending
3. **Study duration** — How long will each patient wear the device?
4. **Data handling** — Ethics approval, consent forms, data privacy requirements?
5. **Clinical correlation** — Will there be reference ECG or other clinical data to validate against?

---

## Document History

| Date | Changes |
|------|---------|
| Nov 2024 | Initial document created |

---

*This document should be updated as decisions evolve during development.*
