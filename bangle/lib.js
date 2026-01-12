// PulseWatch Library - Shared between boot.js and app.js

// it looks like storageFile is not used anywhere?!
let storageFile;
// by defaulte it doesn't record until we let it record in the watch settings
let isRecording = false;
let dataBuffer = [];
let startTime = 0;
let lastSaveTime = 0;
let totalSaved = 0;

const CONFIG = {
  saveInterval: 5 * 60 * 1000,  // 5 minutes for test, should be changed later
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
    file.write("timestamp,bpm,confidence,accel_x,accel_y,accel_z\n");
    
    for (var i = 0; i < dataBuffer.length; i++) {
      var d = dataBuffer[i];
      file.write(d.t + "," + d.b + "," + d.c + "," + 
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

function onHRM(hrm) {
  if (!isRecording) return;

  var accel = Bangle.getAccel();
  var timestamp = Math.floor(Date.now());  // Convert to integer (no decimals)

  // Prepare data object
  var data = {
    t: timestamp,
    b: hrm.bpm || 0,
    c: hrm.confidence || 0,
    x: Math.round(accel.x * 1000),
    y: Math.round(accel.y * 1000),
    z: Math.round(accel.z * 1000)
  };

  // Buffer for file saving (unchanged)
  dataBuffer.push(data);

  // 📡 SEND LIVE DATA OVER BLUETOOTH via Nordic UART Service
  try {
    var line = data.t + "," + data.b + "," + data.c + "," +
               data.x + "," + data.y + "," + data.z;
    Bluetooth.println(line);

    // Debug: Log every 10th reading to console
    if (dataBuffer.length % 10 === 0) {
      console.log("BLE TX: BPM=" + data.b + " Records=" + dataBuffer.length);
    }
  } catch(e) {
    console.log("BLE TX Error: " + e);
  }

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

  Bangle.on('HRM', onHRM);
  Bangle.setHRMPower(1, CONFIG.appName);

  console.log("✅ PulseWatch recording started");
};

exports.stop = function() {
  if (!isRecording) return;
  
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