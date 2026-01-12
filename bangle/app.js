// PulseWatch Control Interface

// call functions from Bangle
Bangle.loadWidgets();
Bangle.drawWidgets();

// ? for what? is it for defining the name of the database?
var pw = require("pulsewatch");

// timstamp such that we keep track of the time data collection
// why we have date but we don't use it?
// what is the condition (m < 10 ? "0" : "")
function formatTime(timestamp) {
  if (!timestamp) return "Never";
  var d = new Date(timestamp);
  var h = d.getHours();
  var m = d.getMinutes();
  return h + ":" + (m < 10 ? "0" : "") + m;
}

// I think it is for the watch desplay, we see the menue using it
function showMainMenu() {
  // status of the watch?
  var status = pw.getStatus();
  
  /* the menu list gonna be as followed:
  PulseWatch AI
  Start or finish the recording (I don't get how it workes)
  show the status if it is recording or not
  number of files created (should check the status.files see if it is implemented correctly or not)
  Storage used
  Last save time so we see when was the last time the file was saved (!!! the problem was we have 0 files but we can see the last save - the problem might be in file creation)
  total recording
  how many readings (we can see the number of readings but still we see 0 files)
  Delete all data
  */
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
      // askes to make sure we wanna delete
      // call the function pw.deleteAllData() - must check the function to see how it is implemented
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

/*
after fixing the errors we must have the automation so that when the watch is connected to the flutter app,
the user don't have to turn on recording, it will go on automatically
Icon of the app should be fixed as well
*/