// PulseWatch Library - Shared between boot.js and app.js

// by defaulte it doesn't record until we let it record in the watch settings
let isRecording = false;
let dataBuffer = [];
let startTime = 0;
let lastSaveTime = 0;
let totalSaved = 0;

// Keep in sync with metadata.json's "version" and the top ChangeLog entry.
// Logged on every load (see the bottom of this file) so the BLE
// console/log makes it immediately obvious which firmware is actually
// running on the watch, rather than having to infer it from behavior.
const VERSION = "0.07";

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

// Keeps pulsewatch.json's "recording" flag in sync with the actual HRM
// listener state, regardless of whether start()/stop() was triggered from
// the watch's own menu (app.js, which already wrote this itself) or
// remotely from the phone over BLE (ble_service.dart's auto-start-on-
// connect, which — before this — only ever called exports.start() and left
// the persisted flag untouched). Without this:
//   - the widget's green recording dot never lit up during normal
//     phone-triggered recording, since widget.js reads this persisted flag,
//     not the live in-memory isRecording state
//   - a watch reboot mid-session (battery pull, crash, etc.) came back up
//     with recording:false and never resumed, since boot.js/widget.js only
//     auto-load and start based on this persisted flag
// Wrapped defensively, matching saveData()'s handling of storage errors —
// a failed write here shouldn't be able to block the actual sensor
// start/stop, which matters more than the persisted flag.
function persistRecordingFlag(value) {
  try {
    var settings = loadSettings();
    settings.recording = value;
    updateSettings(settings);
  } catch (e) {
    // Silent fail
  }
}

// One-time migration: erases pre-fix StorageFile "ghost" chunks — files
// created by the old saveData() (which used Storage.open()/StorageFile
// instead of a plain Storage.write(), see saveData()'s comment) that
// Storage.list()'s default output can't see because of the raw chunk-number
// byte Espruino appends to their stored name. Those files were written
// successfully and are permanently consuming flash, but were never found by
// any Storage.list(/^pw.../) call in this app, so they were never synced or
// erased. Runs once per watch — gated by a persisted flag in
// pulsewatch.json — the first time this fixed lib.js loads; a failure
// leaves the flag unset so it's simply retried on the next load rather than
// giving up permanently.
function cleanupGhostStorageFiles() {
  var settings = loadSettings();
  if (settings.ghostFilesCleaned) return;

  try {
    // {sf:true} asks specifically for StorageFile-type entries — the plain
    // files the fixed saveData() now writes don't carry that flag, so this
    // can't ever touch a current, correctly-synced file. No `$` anchor: the
    // returned raw name may have a trailing chunk byte after ".csv", and
    // matching against it (rather than requiring it) is what let this find
    // the ghost files in the first place.
    var raw = require("Storage").list(/^pw\d+\.csv/, { sf: true });
    var seen = {};
    var erased = 0;
    raw.forEach(function(name) {
      var m = name.match(/^pw\d+\.csv/);
      if (!m) return;
      var logicalName = m[0];
      if (seen[logicalName]) return;
      seen[logicalName] = true;
      // Storage.erase() is documented as not for StorageFiles — opening in
      // read mode and calling .erase() on the StorageFile object is what
      // correctly walks and erases every numbered chunk for this logical
      // name, regardless of how many chunks it actually has.
      require("Storage").open(logicalName, "r").erase();
      erased++;
    });
    console.log("Ghost StorageFile cleanup: erased " + erased + " old chunked file(s)");
  } catch (e) {
    return; // leave ghostFilesCleaned unset — retry next load
  }

  settings.ghostFilesCleaned = true;
  updateSettings(settings);
}

function saveData() {
  if (dataBuffer.length === 0) return;

  try {
    var timestamp = Math.floor(Date.now());  // Convert to integer (no decimals)
    var filename = "pw" + timestamp + ".csv";

    // Plain Storage.write(), not Storage.open()/StorageFile. StorageFile
    // stores content in chunks named "<filename>\1", "\2", etc (the chunk
    // number is a raw byte appended as the *last character* of the stored
    // name) — Storage.list()'s default output includes that suffix, which
    // breaks any regex anchored on `.csv$` (ours, everywhere in this
    // codebase, on both the watch and phone side) since the string no
    // longer ends in ".csv". The file was still written and permanently
    // consumed flash — just invisible to list()/read()/erase() by its
    // logical name, so it could never be synced or cleaned up. A single
    // plain write avoids chunking entirely (our per-flush data is at most
    // ~300 rows / ~12KB, well within one write), matching the plain
    // filename every reader in this app already assumes.
    var lines = ["timestamp,bpm,rr_interval_ms,confidence,accel_x,accel_y,accel_z"];
    for (var i = 0; i < dataBuffer.length; i++) {
      var d = dataBuffer[i];
      lines.push(d.t + "," + d.b + "," + d.r + "," + d.c + "," + d.x + "," + d.y + "," + d.z);
    }
    require("Storage").write(filename, lines.join("\n") + "\n");

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
    r: (Array.isArray(hrm.rr) && hrm.rr.length > 0)
       ? Math.round(hrm.rr[0])
       : (hrm.rr || 0),
    x: Math.round(accel.x * 1000),
    y: Math.round(accel.y * 1000),
    z: Math.round(accel.z * 1000)
  };

  dataBuffer.push(data);

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
  persistRecordingFlag(true);

  console.log("✅ PulseWatch recording started");
};

exports.stop = function() {
  if (!isRecording) return;

  saveData();

  Bangle.removeListener('HRM', onHRM);
  Bangle.setHRMPower(0, CONFIG.appName);

  isRecording = false;
  persistRecordingFlag(false);
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

  // Plain-file erase above misses any StorageFile-chunked ghost entries
  // (see cleanupGhostStorageFiles) — "delete all" should mean all.
  var ghosts = require('Storage').list(/^pw\d+\.csv/, { sf: true });
  var seen = {};
  ghosts.forEach(function(name) {
    var m = name.match(/^pw\d+\.csv/);
    if (!m || seen[m[0]]) return;
    seen[m[0]] = true;
    require('Storage').open(m[0], 'r').erase();
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
console.log("PulseWatch v" + VERSION + " loaded");
cleanupGhostStorageFiles();
exports.reload();