# Creating App Loader Compatible Package

If you want to use the Bangle.js App Loader instead of Web IDE, follow these steps.

---

## Quick Fix for "Unexpected response >" Error

### Option 1: Factory Reset Upload Method ⭐ EASIEST

1. **Put watch in clean state:**
   ```
   - Hold BTN1 + BTN2 together for 6 seconds (full restart)
   - Wait for watch to fully boot
   - DON'T open any apps
   ```

2. **Clear Bluetooth pairing:**
   - On your computer: Settings → Bluetooth
   - Find "Bangle.js" and click "Forget Device"
   - Turn Bluetooth OFF, wait 5 seconds, turn ON

3. **Try App Loader again:**
   - Go to https://banglejs.com/apps/
   - Search for your uploaded app or use custom upload
   - Click Install

---

### Option 2: Use Web IDE (RECOMMENDED)

**Why Web IDE is better:**
- More control over the upload process
- Can see console output
- Better error messages
- Can verify each file uploaded correctly

**How to use:** See `UPLOAD_INSTRUCTIONS.md`

---

## Understanding the App Loader Error

The error `"Install failed: Unexpected response ">"` happens when:

1. **REPL (console) is active** - The ">" is the JavaScript prompt
2. **Another device is connected** - Phone or Web IDE still connected
3. **Previous upload was interrupted** - Partial code still running
4. **Watch is executing code** - App is running in background

**The App Loader expects a "clean" watch** that's not doing anything.

---

## Making Your App Compatible with App Loader

I've already created `app.json` manifest for you. Here's what it does:

```json
{
  "id": "pulsewatch",
  "name": "PulseWatch AI",
  "storage": [
    {"name":"pulsewatch.app.js","url":"app.js"},
    {"name":"pulsewatch.lib.js","url":"lib.js"},
    {"name":"pulsewatch.boot.js","url":"boot.js"},
    {"name":"pulsewatch.wid.js","url":"widget.js"}
  ]
}
```

This tells the App Loader:
- App ID: `pulsewatch`
- Files to upload and their storage names
- How to install them

---

## Method 1: Upload to Official App Loader (Advanced)

If you want your app in the official Bangle.js App Loader:

1. **Fork the BangleApps repository:**
   ```bash
   git clone https://github.com/espruino/BangleApps
   cd BangleApps/apps
   mkdir pulsewatch
   ```

2. **Copy your files:**
   ```bash
   cp /home/user/bangle_programming/bangle/*.js BangleApps/apps/pulsewatch/
   cp /home/user/bangle_programming/bangle/app.json BangleApps/apps/pulsewatch/
   ```

3. **Create a pull request** to the BangleApps repo

4. **Once merged**, your app appears at https://banglejs.com/apps/

---

## Method 2: Host Your Own App Loader (Testing)

For testing, you can host files locally:

1. **Install a simple HTTP server:**
   ```bash
   cd /home/user/bangle_programming/bangle
   python3 -m http.server 8000
   ```

2. **Access App Loader with custom URL:**
   ```
   https://banglejs.com/apps/?id=pulsewatch&url=http://localhost:8000/app.json
   ```

3. **Click Install** - App Loader will fetch from your local server

**Note:** This requires CORS to be enabled. For production, use GitHub Pages or similar.

---

## Method 3: Manual Web IDE Upload (RECOMMENDED FOR NOW)

Since you're still testing, **use the Web IDE method** from `UPLOAD_INSTRUCTIONS.md`.

**Advantages:**
- No App Loader setup needed
- See console output immediately
- Debug issues in real-time
- Can test individual files
- Faster iteration

**Disadvantages:**
- Manual process (but only 2 minutes)
- Need to remember Storage filenames

---

## Creating an Icon (Optional)

If you want a proper icon in the App Loader:

1. **Create a 48x48 PNG image** called `pulsewatch.png`

2. **Update app.json:**
   ```json
   "icon": "pulsewatch.png",
   "storage": [
     {"name":"pulsewatch.img","url":"pulsewatch.png","evaluate":true},
     ...
   ]
   ```

3. **Upload icon to watch via Web IDE:**
   - Storage → Upload File
   - Name: `pulsewatch.img`

---

## Recommended Workflow

**For Development/Testing:**
1. Use **Web IDE** (UPLOAD_INSTRUCTIONS.md)
2. Faster, easier debugging
3. Can update individual files

**For Distribution:**
1. Create proper **app.json** (already done ✅)
2. Submit to BangleApps repository
3. Users can install via App Loader

**For Production:**
1. Test thoroughly with Web IDE
2. Once stable, package for App Loader
3. Create documentation for end users

---

## Current Status

✅ **app.json created** - Ready for App Loader
✅ **All JS files ready** - app.js, lib.js, boot.js, widget.js
⏳ **Icon optional** - Can add later
⏳ **Official listing** - Can submit to BangleApps when ready

---

## What to Do Now

**For immediate testing:**
→ Use Web IDE method (UPLOAD_INSTRUCTIONS.md)

**Once it works:**
→ Keep using Web IDE for development

**When ready for users:**
→ Submit to official BangleApps repository

---

## Why Web IDE is Better for Now

1. **Your app is still in development** - Need to test BLE fixes
2. **Easier to update** - Change code and re-upload in 30 seconds
3. **Better debugging** - See console logs immediately
4. **No packaging needed** - Direct file upload
5. **No connection issues** - Handles REPL prompt correctly

**Use App Loader later** when your app is stable and ready for end users.

---

## Summary

**Problem:** App Loader gave "Unexpected response >" error

**Why:** Watch was in REPL mode, or another connection was active

**Solutions:**
1. ⭐ **Use Web IDE** (UPLOAD_INSTRUCTIONS.md) - RECOMMENDED
2. ⚡ Reset watch completely and try App Loader again
3. 🔧 Host custom App Loader (advanced)

**Files ready:**
- ✅ app.json (manifest)
- ✅ app.js (main app)
- ✅ lib.js (core library) - **WITH BLE FIX**
- ✅ boot.js (auto-start)
- ✅ widget.js (green dot indicator)

**Next step:** Follow `UPLOAD_INSTRUCTIONS.md` to upload via Web IDE.
