// PulseWatch boot - load library if recording enabled
// I don't undrestand how it works but I know it will make the app run in the background
if ((require("Storage").readJSON("pulsewatch.json", 1) || {}).recording) {
  require("pulsewatch");
}