import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'connection_status_service.dart';

/// Entry point flutter_foreground_task calls (in its own isolate — see
/// PulseWatchTaskHandler's doc comment) when the foreground service starts.
@pragma('vm:entry-point')
void foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(PulseWatchTaskHandler());
}

/// Intentionally does no BLE/recording work of its own.
///
/// TaskHandler callbacks run in a separate isolate from the app's main
/// isolate (that's what FlutterForegroundTask.sendDataToMain/sendDataToTask
/// are for) — so `BleService()` accessed from here would be a *different*
/// singleton instance with its own empty state, not the one actually
/// holding the watch connection. This handler exists only to satisfy
/// FlutterForegroundTask.startService()'s API and keep the persistent
/// notification/foreground-service status alive; the real BLE connection,
/// reconnection, and sync logic stays entirely in BleService, running in
/// the main isolate exactly as before — the foreground service just stops
/// Android from killing that isolate's process in the background.
///
/// This same "callbacks run in their own isolate with their own empty
/// state" caveat is why background_sync_service.dart's periodic sync task
/// (a *different* background isolate, spun up by WorkManager rather than
/// by this plugin) can't just check BleService()'s in-memory `isConnected`
/// either — see BleService.performBackgroundSync's doc comment for how it
/// works around that using an OS-level check instead of Dart state.
class PulseWatchTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  // Fires every 60s (see ForegroundTaskOptions.eventAction in
  // ble_service.dart's _ensureForegroundServiceRunning). Purely refreshes
  // "last reading Xm ago" in the notification text so that number keeps
  // climbing live even during a stretch where nothing else happens to
  // trigger an update (no connect/disconnect/reconnect event) — reading
  // ConnectionStatusService's persisted state and DatabaseHelper's last
  // reading timestamp directly rather than needing to hear from whichever
  // isolate currently owns the actual BLE connection, exactly like
  // performBackgroundSync does. This is what makes "is this actually still
  // doing something" answerable by glancing at the notification instead of
  // trusting a value that was set once and never touched again.
  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(ConnectionStatusService.instance.updateNotification());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
