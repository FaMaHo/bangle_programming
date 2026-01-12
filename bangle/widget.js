// PulseWatch Widget

(function() {
  WIDGETS["pulsewatch"] = {
    area: "tr",
    sortorder: 1,
    width: 12,
    draw: function() {
      // Check settings file directly (library might not be loaded)
      var recording = !!(require("Storage").readJSON("pulsewatch.json", 1) || {}).recording;
      if (recording) {
        g.reset();
        g.setColor(0, 1, 0); // Green
        g.fillCircle(this.x + 6, this.y + 12, 4);
      }
    }
  };
  
  // Load library if recording is enabled
  if (!!(require("Storage").readJSON("pulsewatch.json", 1) || {}).recording) {
    require("pulsewatch");
  }
})();