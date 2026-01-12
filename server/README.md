# PulseWatch AI - Test Server

Simple Flask server for receiving CSV data uploads from the PulseWatch Flutter app.

## Setup (MacBook)

1. **Install Python dependencies:**
   ```bash
   cd server
   pip3 install -r requirements.txt
   ```

2. **Find your MacBook's IP address:**
   ```bash
   # Method 1: Use ifconfig
   ifconfig | grep 'inet ' | grep -v 127.0.0.1

   # Method 2: Check System Settings
   # System Settings → Network → Wi-Fi → Details
   ```

   Example IP: `192.168.1.105`

3. **Start the server:**
   ```bash
   python3 test_server.py
   ```

4. **Server will run on:**
   ```
   http://0.0.0.0:5000
   ```

## Configure Flutter App

1. Open PulseWatch app on your phone
2. Go to **Server** tab (cloud icon)
3. Enter your MacBook's IP address:
   ```
   http://192.168.1.105:5000
   ```
4. Tap **Test Connection** to verify
5. Tap **Upload Data to Server** to send data

## What Happens

- CSV files are saved to `uploads/` directory
- Each upload is saved with timestamp: `pulsewatch_data_YYYYMMDD_HHMMSS_device.csv`
- Console shows upload statistics (records count, file size)

## CSV Data Format

The uploaded CSV contains:
- `timestamp`: Unix timestamp in milliseconds
- `bpm`: Heart rate (beats per minute)
- `confidence`: HRM confidence level (0-100)
- `accel_x`: X-axis accelerometer (mg)
- `accel_y`: Y-axis accelerometer (mg)
- `accel_z`: Z-axis accelerometer (mg)
- `device_id`: Device identifier

## Endpoints

- `GET /health` - Health check (returns 200 if server is running)
- `POST /upload` - Upload CSV data
- `GET /stats` - Get upload statistics

## Example Upload

```bash
curl -X POST http://192.168.1.105:5000/upload \
  -H "Content-Type: text/csv" \
  -H "X-Device-ID: flutter-app" \
  --data-binary @sample.csv
```

## Troubleshooting

**Connection Failed:**
- Ensure phone and MacBook are on the same Wi-Fi network
- Check firewall isn't blocking port 5000
- Verify IP address is correct

**No Data to Upload:**
- Connect to Bangle.js watch first
- Enable recording on watch (RECORD toggle)
- Wait for data to be collected

## Next Steps

Once you verify the test server works:
1. Share CSV files with your colleague for ML development
2. Update server URL to point to production server
3. Production server should implement authentication, rate limiting, etc.
