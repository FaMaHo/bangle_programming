// PulseWatch Control Interface

Bangle.loadWidgets();
Bangle.drawWidgets();

// require("pulsewatch") loads lib.js (cached after the first call — see
// bangle/ARCHITECTURE.md) and gives access to its exported recording
// controls (start/stop/getStatus/deleteAllData/reload) used below.
var pw = require("pulsewatch");

// h:mm, e.g. "9:05" — the leading-zero padding is only needed on minutes,
// since hours are never shown zero-padded here.
function formatTime(timestamp) {
  if (!timestamp) return "Never";
  var d = new Date(timestamp);
  var h = d.getHours();
  var m = d.getMinutes();
  return h + ":" + (m < 10 ? "0" : "") + m;
}

// Renders the on-watch settings/status menu (start/stop, files, storage
// used, etc.) shown when the user opens the PulseWatch app from the
// launcher.
function showMainMenu() {
  var status = pw.getStatus();

  var menu = {
    '': { 'title': 'PulseWatch AI' },
    '< Back': function() { load(); },
    'RECORD': {
      value: status.isRecording,
      onchange: function(v) {
        var settings = require("Storage").readJSON("pulsewatch.json", 1) || {};
        settings.recording = v;
        require("Storage").writeJSON("pulsewatch.json", settings);
        pw.reload();
        setTimeout(showMainMenu, 200); // Give reload time to complete
      }
    },
    'Status': {
      value: status.isRecording ? "Recording" : "Stopped"
    },
    'Data Files': {
      value: status.files + " files"
    },
    'Storage Used': {
      value: status.size + " KB"
    },
    'Last Save': {
      value: formatTime(status.lastSave)
    },
    'Total Records': {
      value: status.totalRecordings
    },
    'Buffer': {
      value: status.bufferSize + " readings"
    },
    'Delete All Data': function() {
      E.showPrompt("Delete all data?").then(function(v) {
        if (v) {
          pw.deleteAllData();
          E.showMessage("All data deleted", "Success");
          setTimeout(showMainMenu, 1500);
        } else {
          showMainMenu();
        }
      });
    }
  };
  
  E.showMenu(menu);
}

showMainMenu();

// TODO: app icon still needs fixing.
// (Auto-start-on-phone-connect is already handled — see ble_service.dart's
// _autoStartRecording(), which sends require("pulsewatch").start() over
// BLE right after connecting.)