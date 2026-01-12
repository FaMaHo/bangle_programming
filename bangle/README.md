# PulseWatch AI

Background heart rate and motion data collector for cardiovascular disease research.

## Features

- **Automatic Background Recording**: Starts automatically when watch boots
- **Continuous Monitoring**: Collects heart rate and 3-axis accelerometer data
- **Efficient Storage**: Saves data in 5-minute chunks (configurable to 60 minutes)
- **Visual Indicator**: Small green dot in top-right shows recording is active
- **Zero Interaction**: No user action needed - just wear the watch
- **Battery Efficient**: Uses filtered HRM data to conserve power

## What It Does

PulseWatch runs silently in the background and collects:
- Heart rate (BPM)
- HRM confidence score
- 3-axis accelerometer (X, Y, Z)
- Timestamps for each reading

Data is saved as CSV files in Storage with format: `pwXXXXXXXXXX.csv`

## Data Format

```csv
timestamp,bpm,confidence,accel_x,accel_y,accel_z
1702396800123,72,85,100,-50,980
1702396801123,73,88,105,-48,975
...
```

## For Developers

### Accessing Collected Data

Via Web IDE console:
```javascript
// List all PulseWatch data files
require('Storage').list(/^pw/)

// Read a specific file
var f = require('Storage').open('pw1702396800123.csv', 'r');
f.read(1000);  // Read first 1000 bytes

// Check recording status
require('Storage').readJSON('pulsewatch.json')
```

### Configuration

Edit `boot.js` to change save interval:
```javascript
saveInterval: 60 * 60 * 1000,  // 60 minutes for production
```

## Medical Research Use

This app is designed for hospital-based cardiovascular studies. Data collected is intended for:
- Heart rate variability (HRV) analysis
- Early detection of heart sclerosis
- Motion artifact identification
- Continuous physiological monitoring
