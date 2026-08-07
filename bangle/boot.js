// Runs on every watch boot, before widgets are drawn (see
// bangle/ARCHITECTURE.md). If the last-persisted setting says recording
// was on, load the library so it resumes automatically — otherwise a
// reboot (battery pull, crash, firmware update) would silently drop back
// to not recording until the phone reconnects and re-sends start().
if ((require("Storage").readJSON("pulsewatch.json", 1) || {}).recording) {
  require("pulsewatch");
}