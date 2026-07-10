// PulseWatch Library - Shared between boot.js and app.js

// it looks like storageFile is not used anywhere?!
let storageFile;
// by defaulte it doesn't record until we let it record in the watch settings
let isRecording = false;
let dataBuffer = [];
let liveBuffer = [];
let liveFlushTimer = null;
let startTime = 0;
let lastSaveTime = 0;
let totalSaved = 0;

const CONFIG = {
  saveInterval: 5 * 60 * 1000,  // 5 minutes for test, should be changed later
  // Batch live BLE sends instead of one BLE transmission per HRM sample
  // (~once/sec). Full-fidelity data is always written to flash every
  // saveInterval regardless of BLE connection, so live streaming is just a
  // best-effort feed for the phone's UI/real-time scoring — it doesn't need
  // per-sample latency, and batching cuts radio wake-ups ~15x for battery.
  liveFlushInterval: 15 * 1000,
  appName: "pulsewatch"
};

function loadSettings() {
  var settings = require("Storage").readJSON("pulsewatch.json", 1) || {};
  if (!settings.recording) settings.recording = false;
  return settings;
}

function updateSettings(settings) {
  require("Storage").writeJSON("pulsewatch.json", settings);
}

function saveData() {
  if (dataBuffer.length === 0) return;

  try {
    var timestamp = Math.floor(Date.now());  // Convert to integer (no decimals)
    var filename = "pw" + timestamp + ".csv";
    
    var file = require("Storage").open(filename, "w");
    file.write("timestamp,bpm,rr_interval_ms,confidence,accel_x,accel_y,accel_z\n");
    
    for (var i = 0; i < dataBuffer.length; i++) {
      var d = dataBuffer[i];
      file.write(d.t + "," + d.b + "," + d.r + "," + d.c + "," + 
                 d.x + "," + d.y + "," + d.z + "\n");
    }
    
    totalSaved += dataBuffer.length;
    dataBuffer = [];
    lastSaveTime = Math.floor(Date.now());  // Convert to integer (no decimals)
    
    // Update metadata
    var settings = loadSettings();
    settings.lastSave = timestamp;
    settings.totalRecordings = totalSaved;
    updateSettings(settings);
    
    // Update widget if it exists
    if (global.WIDGETS && WIDGETS["pulsewatch"]) {
      WIDGETS["pulsewatch"].draw();
    }
    
  } catch(e) {
    // Silent fail
  }
}

function formatLine(d) {
  return d.t + "," + d.b + "," + d.r + "," + d.c + "," + d.x + "," + d.y + "," + d.z;
}

// 📡 Sends everything buffered since the last flush as one multi-line BLE
// burst instead of transmitting per sample. The phone app reassembles BLE
// notification fragments and splits multi-line payloads back into
// individual samples, so batching here is transparent to it.
function flushLiveBuffer() {
  if (liveBuffer.length === 0) return;
  try {
    var lines = liveBuffer.map(formatLine).join("\n");
    Bluetooth.println(lines);
    console.log("BLE TX: " + liveBuffer.length + " samples batched");
  } catch(e) {
    console.log("BLE TX Error: " + e);
  }
  liveBuffer = [];
}

function onHRM(hrm) {
  if (!isRecording) return;

  var accel = Bangle.getAccel();
  var timestamp = Math.floor(Date.now());  // Convert to integer (no decimals)

  // Prepare data object
  var data = {
    t: timestamp,
    b: hrm.bpm || 0,
    c: hrm.confidence || 0,
    r: (Array.isArray(hrm.rr) && hrm.rr.length > 0)
       ? Math.round(hrm.rr[0])
       : (hrm.rr || 0),
    x: Math.round(accel.x * 1000),
    y: Math.round(accel.y * 1000),
    z: Math.round(accel.z * 1000)
  };

  // Buffer for file saving (unchanged)
  dataBuffer.push(data);

  // Buffer for the next batched live BLE send (see flushLiveBuffer)
  liveBuffer.push(data);

  // File saving logic (unchanged)
  if (Math.floor(Date.now()) - lastSaveTime >= CONFIG.saveInterval) {
    saveData();
  }
}

exports.start = function() {
  if (isRecording) return;

  isRecording = true;
  startTime = Math.floor(Date.now());  // Convert to integer (no decimals)
  lastSaveTime = Math.floor(Date.now());  // Convert to integer (no decimals)
  dataBuffer = [];
  liveBuffer = [];

  Bangle.on('HRM', onHRM);
  Bangle.setHRMPower(1, CONFIG.appName);
  liveFlushTimer = setInterval(flushLiveBuffer, CONFIG.liveFlushInterval);

  console.log("✅ PulseWatch recording started");
};

exports.stop = function() {
  if (!isRecording) return;

  if (liveFlushTimer) {
    clearInterval(liveFlushTimer);
    liveFlushTimer = null;
  }
  flushLiveBuffer(); // send anything still buffered before stopping
  saveData();

  Bangle.removeListener('HRM', onHRM);
  Bangle.setHRMPower(0, CONFIG.appName);
  
  isRecording = false;
};

exports.isRecording = function() {
  return isRecording;
};

exports.getStatus = function() {
  var files = require('Storage').list(/^pw.*\.csv$/);
  var totalSize = 0;
  files.forEach(function(f) {
    var content = require('Storage').read(f);
    if (content) totalSize += content.length;
  });
  
  var settings = loadSettings();
  
  return {
    isRecording: isRecording,
    files: files.length,
    size: (totalSize / 1024).toFixed(1),
    lastSave: settings.lastSave || 0,
    totalRecordings: settings.totalRecordings || 0,
    bufferSize: dataBuffer.length
  };
};

exports.deleteAllData = function() {
  var files = require('Storage').list(/^pw.*\.csv$/);
  files.forEach(function(f) {
    require('Storage').erase(f);
  });
  
  var settings = loadSettings();
  settings.lastSave = 0;
  settings.totalRecordings = 0;
  updateSettings(settings);
  
  totalSaved = 0;
};

// Reload - restart/stop based on current settings
exports.reload = function() {
  var settings = loadSettings();
  
  // Stop current recording if any
  if (isRecording) {
    if (liveFlushTimer) {
      clearInterval(liveFlushTimer);
      liveFlushTimer = null;
    }
    Bangle.removeListener('HRM', onHRM);
    Bangle.setHRMPower(0, CONFIG.appName);
    isRecording = false;
  }
  
  // Start immediately if recording enabled
  if (settings.recording) {
    exports.start();
  }
};

// Call reload immediately when library loads
exports.reload();