# How to Upload PulseWatch to Bangle.js

## Problem with App Loader
If you get `"Install failed: Unexpected response ">"`, use the Web IDE method instead.

---

## Method 1: Web IDE Upload (RECOMMENDED)

### Step 1: Connect to Bangle.js

1. Go to: https://espruino.com/ide/
2. Click **Connect** (top left)
3. Select **"Web Bluetooth"**
4. Choose your **Bangle.js** from the list
5. Click **Pair**

You should see `>` prompt in the left console panel (this is good!)

---

### Step 2: Clear Existing PulseWatch App (if any)

In the console on the left, type:

```javascript
require("Storage").erase("pulsewatch.app.js");
require("Storage").erase("pulsewatch.lib.js");
require("Storage").erase("pulsewatch.boot.js");
require("Storage").erase("pulsewatch.wid.js");
```

Press Enter after each line. You should see `=undefined` after each command.

---

### Step 3: Upload lib.js (Core Library)

1. Click **"Open File"** (📁 folder icon, top left)
2. Navigate to `/home/user/bangle_programming/bangle/lib.js`
3. The code will appear in the right panel
4. Click **"Storage"** menu (top) → **"Upload File..."**
5. When prompted for filename, type: `pulsewatch.lib.js`
6. Click **OK**

Wait for "Upload Complete!" message.

---

### Step 4: Upload app.js (Main App)

1. Click **"Open File"** again
2. Open `/home/user/bangle_programming/bangle/app.js`
3. Click **"Storage"** → **"Upload File..."**
4. Filename: `pulsewatch.app.js`
5. Click **OK**

---

### Step 5: Upload boot.js (Auto-start)

1. Open `/home/user/bangle_programming/bangle/boot.js`
2. Click **"Storage"** → **"Upload File..."**
3. Filename: `pulsewatch.boot.js`
4. Click **OK**

---

### Step 6: Upload widget.js (Status Indicator)

1. Open `/home/user/bangle_programming/bangle/widget.js`
2. Click **"Storage"** → **"Upload File..."**
3. Filename: `pulsewatch.wid.js`
4. Click **OK**

---

### Step 7: Install the App

In the console (left panel), type:

```javascript
eval(require("Storage").read("pulsewatch.app.js"));
```

Press Enter. The PulseWatch app should appear on your watch!

---

### Step 8: Verify Installation

1. The watch should show the PulseWatch interface
2. You should see **RECORD** toggle and **Status: Idle**
3. A small **green dot** should appear in the top-right corner (widget)

---

### Step 9: Start Recording

1. Tap the **RECORD** toggle
2. Status should change to **"Recording"**
3. Buffer should start increasing: "10 readings", "20 readings", etc.
4. Green dot confirms it's running

---

## Method 2: Quick Upload Script

If Web IDE works but you want to automate it, paste this entire block into the console:

```javascript
// Clear old files
require("Storage").erase("pulsewatch.app.js");
require("Storage").erase("pulsewatch.lib.js");
require("Storage").erase("pulsewatch.boot.js");
require("Storage").erase("pulsewatch.wid.js");

console.log("✅ Old files cleared");
console.log("📤 Now upload files manually via Storage menu:");
console.log("   1. lib.js → pulsewatch.lib.js");
console.log("   2. app.js → pulsewatch.app.js");
console.log("   3. boot.js → pulsewatch.boot.js");
console.log("   4. widget.js → pulsewatch.wid.js");
```

Then follow steps 3-6 from Method 1.

---

## Method 3: Create App Loader Compatible Package

If you really want to use the App Loader, you need an `app.json` manifest.

See `CREATE_APP_PACKAGE.md` for instructions.

---

## Troubleshooting

### "Connection Failed" when connecting to Web IDE
- Turn Bluetooth OFF/ON on your computer
- Restart Bangle.js watch
- Try a different browser (Chrome/Edge work best)
- Make sure watch is not connected to your phone

### "Upload Failed" or "Storage Full"
```javascript
// Check storage space
require("Storage").getFree()
// Should return > 50000

// If low, delete old data files
var files = require("Storage").list(/^pw.*\.csv$/);
files.forEach(f => require("Storage").erase(f));
```

### App doesn't appear after upload
```javascript
// Manually load the app
eval(require("Storage").read("pulsewatch.app.js"));

// Or restart the watch
// Hold BTN1+BTN2 for 6 seconds
```

### Green dot widget not appearing
```javascript
// Manually load widget
eval(require("Storage").read("pulsewatch.wid.js"));
```

### Want to completely remove PulseWatch
```javascript
// Delete all PulseWatch files
require("Storage").erase("pulsewatch.app.js");
require("Storage").erase("pulsewatch.lib.js");
require("Storage").erase("pulsewatch.boot.js");
require("Storage").erase("pulsewatch.wid.js");

// Delete all data files
var files = require("Storage").list(/^pw.*\.csv$/);
files.forEach(f => require("Storage").erase(f));

// Restart watch
load();
```

---

## Verification Checklist

After uploading, verify everything works:

- [ ] PulseWatch app appears on watch
- [ ] Green dot visible in top-right corner
- [ ] Can toggle RECORD on/off
- [ ] Buffer count increases when recording
- [ ] Console shows "BLE TX: BPM=XX Records=XX"
- [ ] Flutter app receives data when connected

---

## Why App Loader Failed

The error `"Unexpected response ">""` means:

1. **Watch was already in REPL mode** (console prompt showing)
2. **Another connection was open** (Web IDE, phone app)
3. **Upload was interrupted** (partial code running)

**Solution:** Use Web IDE instead, which handles the REPL prompt correctly.

---

## Next Steps

Once uploaded successfully:
1. Start recording on watch
2. Connect Flutter app
3. Follow `TESTING_GUIDE.md` to verify data transfer
