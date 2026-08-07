import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';

/// The watch link's real state, as best BleService currently knows it —
/// distinct from whether the Android foreground service process happens to
/// be alive, which is a much weaker signal (a foreground service can keep
/// running for a long time after the actual BLE link underneath it has
/// died; see ble_service.dart's connectionState listener for the incident
/// that motivated tracking this separately).
enum WatchConnectionState { disconnected, connecting, connected, reconnecting }

/// Persisted, isolate-safe record of the watch connection's real state —
/// SharedPreferences rather than an in-memory field because this needs to
/// be read from more than one isolate: the main isolate (interactive UI),
/// the WorkManager background-sync isolate, and the flutter_foreground_task
/// TaskHandler isolate that owns the persistent notification (see
/// foreground_task_handler.dart). None of those share Dart memory with each
/// other.
///
/// This exists to fix a problem the user hit in testing: the foreground
/// notification said "Connected" long after the watch had actually dropped,
/// because its text was set once and never touched again — "everything is
/// hardcoded even the notification."
///
/// [isStale] uses this to detect a silently-dead BLE link for the
/// *interactive* watchdog (see BleService's interactive sync timer).
/// performBackgroundSync() deliberately does NOT consult this state at all
/// — see that method's doc comment for why trusting any reported connection
/// state (this one included) turned out to be the wrong tool for deciding
/// whether background sync is safe to skip.
class ConnectionStatusService {
  ConnectionStatusService._();
  static final ConnectionStatusService instance = ConnectionStatusService._();

  static const _kStateKey = 'watch_conn_state_v1';
  static const _kChangedAtKey = 'watch_conn_changed_at_v1';
  static const _kDeviceLabelKey = 'watch_conn_device_label_v1';

  Future<void> setState(
    WatchConnectionState state, {
    String? deviceLabel,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kStateKey, state.name);
      await prefs.setInt(
        _kChangedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (deviceLabel != null) {
        await prefs.setString(_kDeviceLabelKey, deviceLabel);
      }
    } catch (_) {
      // Best-effort — a failure here shouldn't be able to interrupt the
      // actual connection/sync logic that called this.
    }

    await updateNotification();
  }

  Future<WatchConnectionState> getState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kStateKey);
      return WatchConnectionState.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => WatchConnectionState.disconnected,
      );
    } catch (_) {
      return WatchConnectionState.disconnected;
    }
  }

  Future<DateTime?> getStateChangedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_kChangedAtKey);
      return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    } catch (_) {
      return null;
    }
  }

  /// True if the app believes it's connected, has believed that for at
  /// least [staleness], and yet no reading has reached the local DB in
  /// that same window — the fingerprint of a silently-dead Android BLE
  /// link: `BluetoothGatt` keeps reporting CONNECTED and no
  /// `onConnectionStateChange` ever fires, but notification delivery has
  /// actually stopped. Found in real testing: the watch's own on-device
  /// status confirmed it kept recording and saving to flash the entire
  /// time (independent of BLE), so a gap this long with the app still
  /// claiming "connected" can only mean the *phone's* side of the link
  /// stopped working without telling anyone — reopening the app (which
  /// forces a brand new connect + characteristic re-subscribe) was the
  /// only thing that fixed it in that test, which is exactly the recovery
  /// [BleService] now triggers itself instead of waiting for the user to
  /// notice and relaunch.
  ///
  /// There's no more live BLE push — data only reaches the phone via file
  /// sync, and the watch only has something new to sync every ~5 minutes
  /// (its own flash-checkpoint interval, bangle/lib.js's
  /// CONFIG.saveInterval). [BleService]'s interactive sync timer polls
  /// every 2 minutes, so in the worst-case phase alignment a healthy link
  /// can still go up to ~7 minutes between new readings landing in the DB.
  /// 8 minutes gives a safety margin above that — long enough not to
  /// misfire on a perfectly healthy link's normal poll/flush timing, short
  /// enough to catch a truly dead link well before it costs hours of data.
  Future<bool> isStale({Duration staleness = const Duration(minutes: 8)}) async {
    final state = await getState();
    if (state != WatchConnectionState.connected) return false;

    final changedAt = await getStateChangedAt();
    if (changedAt == null || DateTime.now().difference(changedAt) < staleness) {
      // Too recently connected to judge yet — the first reading hasn't
      // had a fair chance to arrive.
      return false;
    }

    final lastReading = await DatabaseHelper.instance.getLastReadingTime();
    if (lastReading == null) return true; // connected a while, never got one
    return DateTime.now().difference(lastReading) >= staleness;
  }

  /// Refreshes the persistent notification's text to reflect real state —
  /// called immediately on every state transition via [setState], and
  /// periodically (foreground_task_handler.dart's onRepeatEvent, roughly
  /// every 60s) purely to keep "last reading Xm ago" current even when
  /// nothing else has changed. A no-op if the service isn't running or
  /// isn't Android — never throws, since this must not be able to disrupt
  /// whatever real BLE/sync work is happening around it.
  Future<void> updateNotification() async {
    if (!Platform.isAndroid) return;

    try {
      if (!(await FlutterForegroundTask.isRunningService)) return;

      final state = await getState();
      final lastReading = await DatabaseHelper.instance.getLastReadingTime();
      final prefs = await SharedPreferences.getInstance();
      final deviceLabel = prefs.getString(_kDeviceLabelKey) ?? 'watch';

      final String title;
      switch (state) {
        case WatchConnectionState.connected:
          title = 'Connected to $deviceLabel';
          break;
        case WatchConnectionState.reconnecting:
          title = 'Reconnecting to $deviceLabel…';
          break;
        case WatchConnectionState.connecting:
          title = 'Connecting to $deviceLabel…';
          break;
        case WatchConnectionState.disconnected:
          title = 'Not connected';
          break;
      }

      final text = lastReading == null
          ? 'No readings received yet'
          : 'Last reading: ${_relativeTime(lastReading)}';

      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (_) {
      // Best-effort — see class doc comment.
    }
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
