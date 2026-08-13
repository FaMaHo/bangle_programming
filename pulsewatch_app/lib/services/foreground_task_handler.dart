import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'auth_service.dart';
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
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // This isolate is a fresh Dart VM, same as background_sync_service.dart's
    // — DatabaseHelper's in-memory _activeUserId starts unset here regardless
    // of what the main isolate already logged into. Without this,
    // onRepeatEvent's updateNotification() below reads getLastReadingTime()
    // from the generic unscoped database file, which stops receiving writes
    // once the app is scoped correctly elsewhere — so the persistent
    // notification freezes on whatever "last reading" that file last had and
    // never updates again, even while real readings keep landing in the
    // correctly-scoped per-user database the whole time.
    try {
      final patientId = await AuthService.instance.getPatientId();
      await AuthService.instance.switchActiveUser(patientId);
    } catch (_) {
      // Best-effort — the notification just won't reflect real data if this
      // fails, same fallback as background_sync_service.dart.
    }
  }

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
