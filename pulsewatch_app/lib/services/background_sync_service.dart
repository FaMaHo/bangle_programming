import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:workmanager/workmanager.dart';
import 'ble_service.dart';
import 'sync_log_service.dart';

const _kPeriodicSyncTaskName = 'pulsewatch.periodicSync';
const _kPeriodicSyncUniqueName = 'pulsewatch-periodic-sync';

/// Entry point Workmanager calls from its own background isolate — a fresh
/// Dart VM instance with none of the main isolate's in-memory state. That's
/// exactly why BleService.performBackgroundSync() (called below) can't just
/// assume it knows whether the app is already connected — see that method's
/// doc comment for how it avoids racing an interactive session instead.
///
/// @pragma('vm:entry-point') is required for this to survive tree-shaking
/// in release builds: Workmanager's Android side looks this symbol up by
/// name at runtime through a generated plugin registrant, not through a
/// Dart-level call the compiler can trace, so without the pragma a release
/// build can silently strip it and every background sync fails to fire.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    switch (task) {
      case _kPeriodicSyncTaskName:
        // Logged unconditionally, before any skip/connect decision, so a
        // future test can prove whether/how often Android is actually
        // invoking this task at all — every other log entry only gets
        // written once real work is attempted, which left "is the periodic
        // sync even firing" as an open question after the first two rounds
        // of real-device testing (the diagnostics history showed only
        // sparse entries, not enough to tell a genuinely-quiet OS apart
        // from a task that never woke up).
        await SyncLogService.instance.record(
          source: SyncSource.background,
          success: true,
          stage: SyncStage.wake,
          message: 'Background sync task invoked by WorkManager.',
        );

        // Hard ceiling independent of BleService's own internal timeouts
        // (connect timeout, sync timeout) — defense in depth so a bug in a
        // future change to that logic can't turn into a Worker that never
        // returns, which would block Android from ever scheduling the next
        // run for this unique task.
        try {
          final ok = await BleService()
              .performBackgroundSync()
              .timeout(const Duration(minutes: 4));
          return Future.value(ok);
        } catch (_) {
          // Any uncaught exception here — including the timeout above —
          // is reported to WorkManager as a failure, which triggers its
          // built-in exponential backoff before the next retry. The
          // specific reason is already recorded by performBackgroundSync
          // via SyncLogService before this point is reached in the normal
          // failure paths; this catch only guards against something
          // throwing before that logging could happen.
          return Future.value(false);
        }
      default:
        return Future.value(true);
    }
  });
}

/// Owns registering/cancelling the periodic background sync — the
/// mechanism that actually keeps the phone from drifting more than
/// ~15-30 minutes behind whatever the watch has buffered, for as long as
/// the app is installed and a watch is paired, regardless of whether the
/// app is ever reopened in between.
///
/// This replaces "hold one BLE connection open continuously for 48h" as the
/// data-completeness guarantee. That approach fights Android directly:
/// Android 12+'s Doze can defer or drop connections outright even with a
/// foreground service running, foreground services don't reliably survive
/// the app being swiped from Recents, and OEM battery managers (Samsung's
/// included) throttle background processes regardless of how well-behaved
/// the app is. A short, bounded, periodic sync sidesteps all of that: each
/// run is a few seconds to a couple of minutes, so it isn't fighting Doze
/// the way an always-on connection is, and WorkManager itself persists its
/// schedule across process death and device reboots (see
/// RECEIVE_BOOT_COMPLETED in AndroidManifest.xml, which is what lets it
/// reschedule after a reboot).
///
/// The watch side doesn't need to change for this to be safe: bangle/lib.js
/// already checkpoints buffered readings to flash every 5 minutes
/// (CONFIG.saveInterval) independent of whether anything is connected, so a
/// periodic pull only ever delays when data reaches the phone — it can't
/// lose any, the same way the interactive path already couldn't (see
/// ble_service.dart's _readNextFileBangle, which only erases a watch file
/// once its rows are confirmed durably in the phone's DB).
class BackgroundSyncService {
  BackgroundSyncService._();
  static final BackgroundSyncService instance = BackgroundSyncService._();

  bool _initialized = false;

  /// Must be called once from main() before any registration below —
  /// mirrors FlutterForegroundTask.initCommunicationPort()'s "once, before
  /// runApp" requirement already in main.dart. Safe to call more than
  /// once; only the first call does anything.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await Workmanager().initialize(callbackDispatcher);
  }

  /// Schedules the periodic sync if it isn't already scheduled. Idempotent:
  /// ExistingWorkPolicy.keep means calling this while the task is already
  /// registered is a cheap no-op that leaves its existing schedule alone,
  /// rather than resetting the countdown to the next run — so this doesn't
  /// need its own "have I already registered this" bookkeeping and can
  /// just be called every time a connection succeeds (see
  /// BleService.connectToDevice).
  Future<void> ensureScheduled() async {
    if (!_initialized) await init();

    await Workmanager().registerPeriodicTask(
      _kPeriodicSyncUniqueName,
      _kPeriodicSyncTaskName,
      // 15 minutes is Android WorkManager's enforced floor for periodic
      // work — there's no way to get guaranteed background wakeups more
      // often than this without trading away battery life in a way real
      // wearable-companion apps don't either. It's an acceptable bound
      // here specifically because the watch already checkpoints every 5
      // minutes on its own (see the class doc comment above) — nothing is
      // at risk of being lost between runs, only delayed by at most one
      // period.
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      // A failed run (watch out of range, a sync error) retries sooner
      // than the next regular period, backing off exponentially rather
      // than hammering the radio on a fixed short interval — this is
      // WorkManager's own native retry mechanism, not a hand-rolled Dart
      // timer/retry loop, which is what avoids turning "make this more
      // reliable" into "drain the battery scanning constantly".
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 1),
      constraints: Constraints(
        networkType: NetworkType.not_required,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
      ),
    );
  }

  /// Called on logout (see AuthService.logout) — a logged-out install has
  /// no server session to eventually upload synced data to, so there's no
  /// reason to keep waking the device up to pull BLE data for it in the
  /// background. The paired-device id itself is left untouched; logging
  /// back in and reconnecting calls [ensureScheduled] again on its own.
  Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(_kPeriodicSyncUniqueName);
  }
}
