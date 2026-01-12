# PulseWatch AI - System Design Document

**Version:** 1.0  
**Date:** December 12, 2024  
**Project:** Early Heart Sclerosis Detection System

---

## Executive Summary

PulseWatch AI is a medical research system for early detection of heart sclerosis using continuous physiological monitoring. The system consists of:
- **Bangle.js 2 smartwatch** for data collection
- **Flutter mobile app** for data management and user interface
- **Backend server** for data storage and AI analysis

This document outlines the technical architecture for transitioning from live streaming to **chunked batch data transfer** with automatic background recording.

---

## 1. System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     PULSEWATCH AI SYSTEM                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐       ┌──────────────┐       ┌─────────────┐ │
│  │ Bangle.js 2 │◄─BLE─►│ Flutter App  │◄─HTTP─►│   Server    │ │
│  │   (Watch)   │       │   (Mobile)   │       │  (Backend)  │ │
│  └─────────────┘       └──────────────┘       └─────────────┘ │
│        │                      │                       │         │
│   • Records HR             • Receives              • Stores    │
│   • Records Accel          • Validates             • Analysis  │
│   • Buffers data           • Buffers               • ML Model  │
│   • Auto-transfer          • Uploads               • Reports   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Data Collection Requirements

### 2.1 What We Need to Collect

Based on cardiovascular research:

| Data Type | Sampling Rate | Why It's Critical |
|-----------|---------------|-------------------|
| **Heart Rate (BPM)** | 25-50 Hz | Basic cardiovascular monitoring |
| **RR Intervals** | Every heartbeat | Essential for HRV analysis (heart sclerosis detection) |
| **HRM Confidence** | Every reading | Signal quality validation |
| **Accelerometer (X,Y,Z)** | 25-50 Hz | Motion artifact removal |
| **Timestamp** | Every reading | Temporal correlation |
| **Signal Quality Index** | Every reading | Data validation |

### 2.2 Scientific Justification

- **Research Finding:** HRV changes appear BEFORE clinical symptoms
- **Minimum Sampling Rate:** 25 Hz (no significant HRV metric differences above this)
- **Optimal Sampling Rate:** 50 Hz (balance accuracy vs battery)
- **Motion Artifacts:** 44.6% rejection rate is normal - we handle this with accelerometer data
- **Critical:** We need **beat-to-beat intervals (RR)**, not just averaged BPM

---

## 3. Watch-Side Design (Bangle.js 2)

### 3.1 Storage Capacity Analysis

```
Available Storage: 8388.61 KiB total (~8.2 MB)
Current Usage: 489 KB (6%)
Available: ~7.7 MB (94%)

Data Size Calculations:
- 25Hz sampling: ~2.16 MB per hour
- 50Hz sampling: ~4.32 MB per hour

Buffer Capacity:
- At 25Hz: Can buffer ~3.5 hours before transfer
- At 50Hz: Can buffer ~1.8 hours before transfer

DECISION: Use 25Hz with hourly transfers (5min for testing)
```

### 3.2 Implementation Strategy

**Option Selected:** Extend existing "Recorder" app with custom `.recorder.js` file

**Why this approach:**
- ✅ Leverages proven, stable codebase
- ✅ Built-in data storage and export mechanisms
- ✅ Already does background recording
- ✅ No need to reinvent the wheel
- ✅ Less risk of breaking watch functionality

### 3.3 Custom Data Recorder

**File:** `pulsewatch.recorder.js`

**Data Fields:**
```javascript
[
  "timestamp",        // Unix milliseconds
  "hr_bpm",          // Heart rate in BPM
  "rr_interval_ms",  // Time between beats (calculated from BPM)
  "hrm_confidence",  // HRM sensor confidence (0-100)
  "accel_x",         // Accelerometer X * 1000 (as integer)
  "accel_y",         // Accelerometer Y * 1000 (as integer)
  "accel_z",         // Accelerometer Z * 1000 (as integer)
  "signal_quality"   // Calculated quality index (0-100)
]
```

**Recording Intervals:**
- **Testing:** 5 minutes (for quick validation)
- **Production:** 60 minutes (for 48-hour pilot studies)

### 3.4 Data Transfer Protocol

```
WATCH BEHAVIOR:
1. Record data continuously in background
2. Every N minutes, check if phone is connected
3. If connected:
   a. Send "DATA_READY" notification via UART
   b. Wait for "REQUEST_DATA" from phone
   c. Send data as CSV chunks (max 512 bytes per chunk)
   d. Wait for "CONFIRM_RECEIVED" from phone
   e. DELETE local data after confirmation
4. If not connected:
   a. Continue buffering (up to 3 hours max)
   b. Show notification to user if buffer > 80% full
```

**BLE Services Used:**
- **UART Service:** `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- **UART TX (to phone):** `6e400003-b5a3-f393-e0a9-e50e24dcca9e`
- **UART RX (from phone):** `6e400002-b5a3-f393-e0a9-e50e24dcca9e`

**Message Format:**
```json
// Watch → Phone
{
  "type": "DATA_READY",
  "timestamp": 1702396800000,
  "recordCount": 7500,
  "chunkCount": 15
}

// Phone → Watch
{
  "type": "REQUEST_CHUNK",
  "chunkIndex": 0
}

// Watch → Phone (data chunk)
{
  "type": "DATA_CHUNK",
  "chunkIndex": 0,
  "chunkCount": 15,
  "data": "timestamp,hr_bpm,rr_interval_ms,hrm_confidence,accel_x,..."
}

// Phone → Watch (confirmation)
{
  "type": "CONFIRM_CHUNK",
  "chunkIndex": 0
}

// When all chunks received
{
  "type": "TRANSFER_COMPLETE"
}
```

### 3.5 Watch UI/UX

**User Interaction:** ZERO interaction required
- Recording starts automatically on boot
- Widget shows recording status (green dot)
- Notification if phone disconnected > 2 hours
- Notification if storage > 80% full

---

## 4. Flutter App Design

### 4.1 New Features Required

| Feature | Priority | Description |
|---------|----------|-------------|
| User Authentication | HIGH | Login/signup with user ID for data association |
| Auto-connect | HIGH | Remember last device, auto-reconnect |
| Chunked Data Reception | CRITICAL | Handle hourly data transfers from watch |
| Data Validation | HIGH | Check signal quality, reject bad data |
| Local Buffering | HIGH | SQLite storage for offline capability |
| Background Sync | MEDIUM | Upload to server when WiFi available |
| Notifications | MEDIUM | Alert user of connection issues |
| Export Functionality | HIGH | CSV export for researchers |

### 4.2 Updated Database Schema

**New Tables:**

```sql
-- Users table
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT UNIQUE NOT NULL,
  email TEXT,
  name TEXT,
  created_at INTEGER
);

-- Enhanced heart_rate table
CREATE TABLE heart_rate (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  bpm INTEGER NOT NULL,
  rr_interval_ms INTEGER,           -- NEW: For HRV analysis
  hrm_confidence INTEGER,            -- NEW: Signal quality
  signal_quality INTEGER,            -- NEW: Calculated SQI
  device_id TEXT,
  sync_status TEXT DEFAULT 'pending', -- NEW: 'pending', 'synced', 'failed'
  sync_timestamp INTEGER,
  FOREIGN KEY (user_id) REFERENCES users(user_id)
);

-- Enhanced accelerometer table
CREATE TABLE accelerometer (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  x INTEGER NOT NULL,
  y INTEGER NOT NULL,
  z INTEGER NOT NULL,
  device_id TEXT,
  sync_status TEXT DEFAULT 'pending',
  sync_timestamp INTEGER,
  FOREIGN KEY (user_id) REFERENCES users(user_id)
);

-- Sessions table (enhanced)
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  start_time INTEGER NOT NULL,
  end_time INTEGER,
  total_readings INTEGER DEFAULT 0,
  data_quality_score REAL,           -- NEW: Average signal quality
  sync_status TEXT DEFAULT 'pending',
  FOREIGN KEY (user_id) REFERENCES users(user_id)
);

-- Data chunks tracking (NEW)
CREATE TABLE data_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  session_id INTEGER,
  chunk_timestamp INTEGER NOT NULL,
  record_count INTEGER,
  received_at INTEGER,
  validated INTEGER DEFAULT 0,       -- 0=pending, 1=valid, -1=invalid
  FOREIGN KEY (user_id) REFERENCES users(user_id),
  FOREIGN KEY (session_id) REFERENCES sessions(id)
);

-- Indexes for performance
CREATE INDEX idx_hr_user_time ON heart_rate(user_id, timestamp);
CREATE INDEX idx_hr_sync ON heart_rate(sync_status);
CREATE INDEX idx_accel_user_time ON accelerometer(user_id, timestamp);
```

### 4.3 App Architecture

```
lib/
├── main.dart
├── theme/
│   └── app_theme.dart
├── models/
│   ├── user_model.dart              [NEW]
│   ├── heart_rate_model.dart        [ENHANCED]
│   └── data_chunk_model.dart        [NEW]
├── services/
│   ├── ble_service.dart             [ENHANCED]
│   ├── database_helper.dart         [ENHANCED]
│   ├── auth_service.dart            [NEW]
│   ├── sync_service.dart            [NEW]
│   └── validation_service.dart      [NEW]
├── screens/
│   ├── auth_screen.dart             [NEW]
│   ├── today_screen.dart            [ENHANCED]
│   ├── insights_screen.dart         [ENHANCED]
│   └── device_screen.dart           [ENHANCED]
└── widgets/
    ├── connection_status.dart       [NEW]
    └── sync_indicator.dart          [NEW]
```

### 4.4 BLE Service Enhancements

**New Capabilities:**

```dart
class BleService {
  // Existing capabilities
  Stream<int> heartRateStream;
  Stream<AccelerometerData> accelerometerStream;
  
  // NEW: Chunked data transfer
  Stream<DataChunkProgress> chunkTransferProgress;
  
  // NEW: Methods
  Future<void> requestDataTransfer();
  Future<bool> receiveDataChunk(int chunkIndex);
  Future<void> confirmChunkReceived(int chunkIndex);
  Future<void> completeTransfer();
  
  // NEW: Auto-reconnect
  Future<void> enableAutoReconnect(String deviceId);
  Future<void> attemptReconnect();
}
```

### 4.5 Data Flow

```
USER OPENS APP
    ↓
[Check if user logged in]
    ↓ NO → Show Login Screen
    ↓ YES
[Load user profile]
    ↓
[Check for saved device]
    ↓ YES → Auto-scan for device
    ↓ NO → User must scan & connect manually
    ↓
[Connected to watch]
    ↓
[Listen for "DATA_READY" notifications]
    ↓
[Request data chunks sequentially]
    ↓
[Validate each chunk (signal quality)]
    ↓
[Store in local SQLite]
    ↓
[Confirm receipt to watch]
    ↓
[Watch deletes local copy]
    ↓
[Check network connectivity]
    ↓ WiFi → Upload to server
    ↓ No WiFi → Keep in local buffer
    ↓
[Update UI with new stats]
```

---

## 5. Data Validation Strategy

### 5.1 Signal Quality Criteria

**Reject data if:**
- Heart rate < 40 BPM or > 200 BPM
- HRM confidence < 30%
- Calculated signal quality < 40%
- Excessive motion artifacts (accelerometer magnitude > threshold)

**Quality Scoring:**
```javascript
Signal Quality Index (SQI) = 
  0.4 * HRM_Confidence + 
  0.3 * HR_Validity_Score + 
  0.3 * Motion_Stability_Score

Where:
- HRM_Confidence: From sensor (0-100)
- HR_Validity_Score: 100 if 40 < HR < 200, else 0
- Motion_Stability_Score: 100 - (motion_magnitude * scaling_factor)
```

### 5.2 Validation in Flutter

```dart
class ValidationService {
  static const int MIN_HR = 40;
  static const int MAX_HR = 200;
  static const int MIN_CONFIDENCE = 30;
  static const int MIN_QUALITY = 40;
  
  bool validateHeartRateReading(HeartRateData data) {
    if (data.bpm < MIN_HR || data.bpm > MAX_HR) return false;
    if (data.confidence < MIN_CONFIDENCE) return false;
    if (data.signalQuality < MIN_QUALITY) return false;
    return true;
  }
  
  double calculateDataQualityScore(List<HeartRateData> chunk) {
    int validCount = chunk.where((d) => validateHeartRateReading(d)).length;
    return (validCount / chunk.length) * 100;
  }
}
```

---

## 6. User Experience Design

### 6.1 First-Time Setup Flow

```
1. User opens app for first time
   ↓
2. Welcome screen explaining PulseWatch
   ↓
3. Sign up / Login screen
   ↓
4. Grant Bluetooth permissions
   ↓
5. "Scan for your Bangle.js watch"
   ↓
6. List of devices appears
   ↓
7. User taps their watch
   ↓
8. Connection established
   ↓
9. "✓ Connected! Your watch is now recording automatically"
   ↓
10. Tutorial: "You can now close the app. We'll sync data automatically."
```

### 6.2 Daily Usage Flow

```
MORNING:
- User wakes up, wears watch
- Watch automatically starts recording (if not already)

THROUGHOUT DAY:
- User doesn't need to open app
- Every hour, watch tries to sync if phone nearby
- If sync fails, watch buffers data

EVENING:
- User opens app (optional)
- Sees today's stats updated
- Sees "Last synced: 2 hours ago"

EVERY 48 HOURS:
- Complete data automatically uploaded to server (when WiFi available)
```

### 6.3 Notification Strategy

**When to Notify User:**
- ⚠️ Watch disconnected for > 2 hours: "Please bring your phone near your watch to sync"
- ⚠️ Watch storage > 80% full: "Critical: Connect to sync data or data will be lost"
- ✅ Daily sync complete: "Today's health data synced successfully"
- ⚠️ Low data quality detected: "Please wear watch tighter for better readings"

**When NOT to Notify:**
- Normal hourly syncs (silent)
- App running in background

---

## 7. Backend Server Integration

### 7.1 API Endpoints

```
POST /api/auth/register
POST /api/auth/login
POST /api/data/upload
GET  /api/data/sync-status
POST /api/data/export-csv
GET  /api/user/profile
```

### 7.2 Data Upload Format

```json
{
  "user_id": "user123",
  "device_id": "Bangle.js:XX:XX:XX",
  "session_start": 1702396800000,
  "session_end": 1702400400000,
  "heart_rate_data": [
    {
      "timestamp": 1702396800000,
      "bpm": 72,
      "rr_interval_ms": 833,
      "confidence": 85,
      "signal_quality": 78
    },
    // ... more readings
  ],
  "accelerometer_data": [
    {
      "timestamp": 1702396800000,
      "x": 150,
      "y": -200,
      "z": 980
    },
    // ... more readings
  ],
  "data_quality_score": 82.5
}
```

### 7.3 Upload Strategy

**When to Upload:**
- WiFi available AND data > 1 hour old
- User manually triggers export
- Every 24 hours (forced sync)

**Chunked Upload:**
- Max 1 hour of data per HTTP request
- If upload fails, retry with exponential backoff
- Mark records as 'synced' only after 200 OK response

---

## 8. Battery Life Optimization

### 8.1 Watch-Side

```
HRM Power Management:
- Use Bangle.setHRMPower(1, "pulsewatch") only when recording
- 25Hz sampling vs 50Hz: ~2x battery life improvement
- Expected battery life: ~36-48 hours with continuous HRM

Storage Optimization:
- Use binary storage instead of JSON where possible
- Compress CSV data before transfer
- Delete transferred data immediately

BLE Optimization:
- Only advertise DATA_READY, don't stream continuously
- Use notification instead of polling
```

### 8.2 App-Side

```
Background Processing:
- Use Flutter background services for data sync
- Reduce BLE scanning frequency when not actively connecting
- Batch database writes

Network Optimization:
- Only upload on WiFi (avoid mobile data charges)
- Compress data before upload
- Implement resume capability for interrupted uploads
```

---

## 9. Testing Strategy

### 9.1 Phase 1: Basic Connectivity (Week 1)

**Goal:** Verify watch can communicate with app

**Tests:**
- [ ] Watch can be discovered by app
- [ ] App can connect to watch
- [ ] App can receive "DATA_READY" notification
- [ ] Connection remains stable for 5 minutes

### 9.2 Phase 2: Data Transfer (Week 1-2)

**Goal:** Verify chunked data transfer works

**Tests:**
- [ ] Watch sends data in 512-byte chunks
- [ ] App receives all chunks correctly
- [ ] App confirms receipt, watch deletes data
- [ ] Transfer works with 5-minute test interval
- [ ] Data stored correctly in SQLite

### 9.3 Phase 3: Data Validation (Week 2)

**Goal:** Verify data quality

**Tests:**
- [ ] Signal quality calculation is correct
- [ ] Bad data is rejected
- [ ] Motion artifacts are detected
- [ ] Quality score matches expected values

### 9.4 Phase 4: Authentication & Sync (Week 3)

**Goal:** End-to-end system works

**Tests:**
- [ ] User can register/login
- [ ] Data associated with correct user
- [ ] Data uploads to server correctly
- [ ] CSV export works

### 9.5 Phase 5: Pilot Study (Week 4+)

**Goal:** Real-world testing

**Tests:**
- [ ] 48-hour continuous recording
- [ ] Battery lasts 48+ hours
- [ ] Data quality acceptable (>50% valid)
- [ ] No data loss
- [ ] System handles connection interruptions

---

## 10. Implementation Roadmap

### Week 1: Foundation
- **Day 1-2:** Create custom `pulsewatch.recorder.js` for watch
- **Day 3-4:** Implement chunked data transfer protocol in BleService
- **Day 5-7:** Update database schema and add validation logic

### Week 2: Core Features
- **Day 1-2:** Build authentication system
- **Day 3-4:** Implement data sync service
- **Day 5-7:** Add notifications and background processing

### Week 3: Polish & Testing
- **Day 1-2:** Comprehensive testing of data transfer
- **Day 3-4:** Fix bugs, optimize battery life
- **Day 5-7:** User testing with 5-minute intervals

### Week 4: Production Prep
- **Day 1-3:** Change to 60-minute intervals
- **Day 4-5:** Final testing
- **Day 6-7:** Deploy for pilot study

---

## 11. Risk Mitigation

### 11.1 Identified Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Data loss during transfer | HIGH | MEDIUM | Confirmation protocol, retry logic |
| Watch battery dies before sync | HIGH | LOW | Notify at 80% storage, 48hr battery spec |
| BLE connection unstable | HIGH | MEDIUM | Auto-reconnect, buffer data locally |
| Server unavailable | MEDIUM | LOW | Local buffering, batch uploads |
| Poor data quality | MEDIUM | MEDIUM | Real-time validation, user feedback |
| User forgets to wear watch | LOW | HIGH | Daily reminder notifications |

### 11.2 Contingency Plans

**If BLE transfer fails repeatedly:**
- Fallback to exporting via App Loader download interface
- Manual CSV transfer via USB

**If data quality consistently low:**
- Add UI guidance: "Wear watch snugly", "Clean sensor"
- Implement adaptive sampling (increase rate during poor quality periods)

**If battery life insufficient:**
- Reduce sampling rate to 10Hz
- Implement smart sampling (higher rate during rest, lower during activity)

---

## 12. Success Criteria

### Technical Success
- ✅ 48-hour battery life achieved
- ✅ <5% data loss rate
- ✅ >50% data quality score
- ✅ Successful hourly syncs >90% of time
- ✅ Zero crashes during pilot study

### User Experience Success
- ✅ Setup takes <5 minutes
- ✅ Users rate ease of use >4/5
- ✅ Zero intervention needed after setup
- ✅ Clear, actionable notifications

### Research Success
- ✅ Sufficient HRV data collected for AI model
- ✅ Motion artifact removal >40% effective
- ✅ Data suitable for cardiovascular analysis
- ✅ 20-30 patients successfully complete 48hr monitoring

---

## 13. Next Steps

### Immediate Action Items

**Before Coding:**
1. [ ] Review this document together
2. [ ] Clarify any ambiguous points
3. [ ] Agree on implementation order
4. [ ] Set up development environment

**First Code Session:**
1. [ ] Start with watch-side custom recorder
2. [ ] Test basic data collection (print to console)
3. [ ] Verify storage usage is acceptable
4. [ ] Commit working version before moving forward

**Incremental Development:**
- Build one feature at a time
- Test each feature thoroughly before next
- Maintain working version at each step
- Document any deviations from this plan

---

## 14. Open Questions / Decisions Needed

1. **Authentication Method:** Email/password or phone number OTP?
2. **Server Location:** Where will backend be hosted (China/outside China)?
3. **Data Retention:** How long to keep data on phone before deletion?
4. **Privacy:** Encryption at rest? End-to-end encryption during transfer?
5. **Multi-device:** Can one user pair multiple watches?
6. **Research Protocol:** IRB approval status? Consent form integration?

---

## Appendix A: Technical Specifications

**Bangle.js 2:**
- Processor: nRF52832 (64MHz ARM Cortex-M4)
- RAM: 64KB
- Flash: 512KB
- Storage: ~400KB available for apps/data
- Battery: 200mAh (~48hr typical use)
- HRM: MAX30102 optical sensor
- Accelerometer: KX023-1025 (3-axis)
- BLE: 4.0+

**Flutter App:**
- Minimum Android: 6.0 (API 23)
- Target Android: 14 (API 34)
- Minimum iOS: 12.0
- Flutter SDK: >=3.0.0
- Key packages: flutter_blue_plus, sqflite, http, shared_preferences

**Backend Server:**
- Specs: Quad-core 2.0 GHz, 8GB RAM, 500GB SSD
- OS: Ubuntu 22.04 LTS
- Database: PostgreSQL 14+ with TimescaleDB
- API: Flask/FastAPI
- Containerization: Docker

---

## Document Control

**Version History:**
- v1.0 (2024-12-12): Initial comprehensive design document

**Review Status:** 
- [ ] Reviewed by Fatemeh
- [ ] Technical details confirmed
- [ ] Ready for implementation

**Approval:**
- [ ] Technical architecture approved
- [ ] Implementation order approved
- [ ] Ready to start coding

---

*End of Design Document*
