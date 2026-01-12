# 🚨 QUICK FIX: Bangle.js Upload Error

## Your Error
```
Install failed: Unexpected response ">"
```

## What This Means
The ">" is the JavaScript console prompt. The watch is in REPL mode, not ready for App Loader.

---

## ⭐ SOLUTION 1: Use Web IDE (RECOMMENDED)

**Why:** More reliable, can see what's happening, easier to debug.

**How:** Follow these 5 steps:

### 1. Connect
- Go to: https://espruino.com/ide/
- Click **Connect** → **Web Bluetooth**
- Select your **Bangle.js**

### 2. Clear Old App (if any)
Paste in console (left side):
```javascript
require("Storage").erase("pulsewatch.app.js");
require("Storage").erase("pulsewatch.lib.js");
require("Storage").erase("pulsewatch.boot.js");
require("Storage").erase("pulsewatch.wid.js");
```

### 3. Upload Files
For each file (`lib.js`, `app.js`, `boot.js`, `widget.js`):
- Open file (📁 icon)
- **Storage** menu → **Upload File...**
- Name it: `pulsewatch.FILENAME.js`
  - lib.js → `pulsewatch.lib.js`
  - app.js → `pulsewatch.app.js`
  - boot.js → `pulsewatch.boot.js`
  - widget.js → `pulsewatch.wid.js`

### 4. Load App
Type in console:
```javascript
eval(require("Storage").read("pulsewatch.app.js"));
```

### 5. Verify
- PulseWatch app should appear on watch
- Green dot in top-right corner
- Can toggle RECORD on/off

**Done!** ✅

---

## 🔄 SOLUTION 2: Try App Loader Again (Quick Fix)

If you really want to use App Loader:

### 1. Clean Slate
```
1. Hold BTN1 + BTN2 for 6 seconds (restart watch)
2. Don't open any apps after restart
3. Forget Bluetooth pairing on computer
4. Turn Bluetooth OFF → wait 5 sec → ON
```

### 2. Try Upload Again
- https://banglejs.com/apps/
- Try installing your app

If still fails → **Use Web IDE** (Solution 1)

---

## 📁 File Locations
All files are in: `/home/user/bangle_programming/bangle/`
- `lib.js` - Core library (has BLE fix!)
- `app.js` - Main app
- `boot.js` - Auto-start
- `widget.js` - Green dot indicator

---

## 📖 Detailed Guides

- **Step-by-step Web IDE:** `bangle/UPLOAD_INSTRUCTIONS.md`
- **App Loader setup:** `bangle/CREATE_APP_PACKAGE.md`
- **BLE testing:** `TESTING_GUIDE.md`

---

## ⏱️ Time Required

**Web IDE Method:** 2-3 minutes
**App Loader Fix:** 1 minute (if it works)

**Recommendation:** Use Web IDE for now. It's more reliable for custom apps.

---

## ✅ Success Checklist

After upload, you should see:
- [ ] PulseWatch app on watch screen
- [ ] Green dot widget in top-right corner
- [ ] Can toggle RECORD button
- [ ] Status shows "Idle" or "Recording"
- [ ] Buffer count increases when recording

---

## 🆘 Still Having Issues?

**Console logs not showing up?**
→ Check if watch is connected in Web IDE (green indicator)

**Files won't upload?**
→ Run this to free space:
```javascript
var files = require("Storage").list(/^pw.*\.csv$/);
files.forEach(f => require("Storage").erase(f));
```

**App doesn't appear?**
→ Type in console:
```javascript
load();  // Refresh watch UI
```

**Need more help?**
→ Read `bangle/UPLOAD_INSTRUCTIONS.md` for detailed troubleshooting

---

## Next Step

Once uploaded:
→ Follow `TESTING_GUIDE.md` to test BLE data transfer with Flutter app
