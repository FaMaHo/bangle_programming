# BLE Data Transfer Testing Guide

## Problem Fixed
**Root Cause:** Bangle.js was using `NRF.send()` which sends data via BLE advertising packets, NOT via Nordic UART Service (NUS).

**Solution:** Changed to `Bluetooth.println()` which properly sends data through the Nordic UART Service that Flutter is listening to.

---

## Testing Steps

### 1. Upload Fixed Code to Bangle.js

1. Open Bangle.js App Loader: https://banglejs.com/apps/
2. Upload the following files FROM `/home/user/bangle_programming/bangle/`:
   - `lib.js` (the fixed version)
   - `app.js`
   - `boot.js`
   - `widget.js`

### 2. Verify Bangle.js is Recording

1. On your Bangle.js watch, open the PulseWatch app
2. Toggle **RECORD** to ON
3. You should see:
   - **Status**: Recording
   - **Buffer**: Should increase (e.g., "10 readings", "20 readings")

4. Connect to Bangle.js via Chrome/Edge:
   - Go to https://espruino.com/ide/
   - Click "Connect" → Select your Bangle.js
   - Open the Console (left side)
   - You should see logs like:
     ```
     ✅ PulseWatch recording started
     BLE TX: BPM=72 Records=10
     BLE TX: BPM=75 Records=20
     ```

### 3. Test Flutter App Connection

1. Build and run the Flutter app:
   ```bash
   cd /home/user/bangle_programming/pulsewatch_app
   flutter run
   ```

2. In the app:
   - Go to **Device** tab (third tab)
   - Tap **"Scan for Devices"**
   - Find your Bangle.js (usually named "Bangle.js xxxx")
   - Tap **"Connect"**

3. Check Flutter logs (in your terminal):
   ```
   🔍 Detected device type: DeviceType.bangleJS
   ✅ Found Bangle.js UART Service
   ✅ Bangle TX characteristic ready
   ✅ Bangle RX characteristic ready
   ✅ Connected successfully to DeviceType.bangleJS!
   ```

### 4. Verify Live Data Reception

Once connected, check your Flutter terminal for:
```
📥 Received: 1738425678123,75,95,123,-456,789
💾 Saved to DB: HR=75 BPM
```

If you don't see this, check:
1. Is recording ON on the watch?
2. Is the watch on your wrist? (HRM needs skin contact)
3. Check Flutter logs for any errors

### 5. Verify Database Storage

In the Today screen, you should see:
- **Heart Rate**: Current BPM updating in real-time
- **Signal Score**: Increasing as data comes in
- **Min / Avg / Max**: Heart rate statistics

To manually check the database:
```bash
cd /home/user/bangle_programming/pulsewatch_app
flutter run
# Then in Dart DevTools console:
BleService().getDatabaseStats()
```

You should see:
```json
{
  "total_hr_readings": 150,
  "total_accel_readings": 150,
  "first_reading": "2025-01-12 10:30:00",
  "last_reading": "2025-01-12 10:35:00",
  "duration_hours": 0.083
}
```

---

## Debugging Checklist

### ❌ No data received in Flutter app

**Check:**
1. Is Bangle.js recording enabled?
   - Open PulseWatch app → RECORD should be ON
2. Is the watch on your wrist?
   - HRM sensor needs skin contact
3. Check Bangle.js console logs:
   - Connect via Web IDE (espruino.com/ide)
   - Should see "BLE TX: BPM=xx"
4. Check Flutter logs:
   - Should see "Found Bangle.js UART Service"

**Still not working?**
- Try disconnecting and reconnecting
- Restart the Bangle.js watch
- Reinstall the PulseWatch app on Bangle.js

### ❌ Connection fails

**Check:**
1. Bluetooth is enabled on phone
2. Location permission granted (required for BLE on Android)
3. Bangle.js is not connected to another device
4. Try forgetting the device and reconnecting

### ❌ Data stops after a while

**Check:**
1. Watch battery level (should be >20%)
2. Phone didn't go to sleep (check battery optimization settings)
3. Bluetooth connection is stable (stay within 10m range)

---

## Expected Data Flow

```
┌─────────────────┐
│   Bangle.js     │  Every HRM reading (~1 second):
│                 │  1. Collect HR + Accelerometer
│   lib.js:86     │  2. Bluetooth.println("timestamp,bpm,conf,x,y,z")
└────────┬────────┘
         │ BLE Nordic UART Service
         │ (TX: 6e400002, RX: 6e400003)
         ▼
┌─────────────────┐
│  Flutter App    │  ble_service.dart:230
│                 │  1. Listen to RX characteristic
│  _subscribeToUA │  2. Parse CSV line (6 fields)
│  RTBangle()     │  3. Save to SQLite database
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  SQLite DB      │  Tables:
│                 │  - heart_rate (timestamp, bpm, confidence)
│  pulsewatch.db  │  - accelerometer (timestamp, x, y, z)
└─────────────────┘
```

---

## Data Format

### Live Data (sent by Bangle.js)
```
1738425678123,75,95,123,-456,789
│             │  │  │   │    └─ accel_z (mG * 1000)
│             │  │  │   └────── accel_y (mG * 1000)
│             │  │  └────────── accel_x (mG * 1000)
│             │  └───────────── confidence (0-100)
│             └──────────────── bpm (beats per minute)
└────────────────────────────── timestamp (ms since epoch)
```

### Database Schema
```sql
CREATE TABLE heart_rate (
    id INTEGER PRIMARY KEY,
    timestamp INTEGER NOT NULL,  -- Unix timestamp (ms)
    bpm INTEGER NOT NULL,         -- Heart rate (BPM)
    confidence INTEGER,           -- Signal quality (0-100)
    device_id TEXT                -- Bangle.js MAC address
);

CREATE TABLE accelerometer (
    id INTEGER PRIMARY KEY,
    timestamp INTEGER NOT NULL,  -- Unix timestamp (ms)
    x INTEGER NOT NULL,           -- X-axis (mG * 1000)
    y INTEGER NOT NULL,           -- Y-axis (mG * 1000)
    z INTEGER NOT NULL,           -- Z-axis (mG * 1000)
    device_id TEXT                -- Bangle.js MAC address
);
```

---

## Success Criteria

✅ **Test Passed** when:
1. Bangle.js shows "Recording" status
2. Flutter app connects successfully
3. "Live HR: XX BPM • XXX readings" appears in Device screen
4. Database has >100 readings after 2 minutes
5. Today screen shows current heart rate updating

---

## Next Steps After Testing

Once data transfer works:
1. Test file sync feature (for saved CSV files on watch)
2. Implement server upload to Flask backend
3. Add AI model prediction endpoint
4. Test full pipeline: Watch → App → Server → AI → Results
