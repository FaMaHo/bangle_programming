import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a sync attempt originated from — the interactive UI (user tapped
/// "Connect", or the app auto-reconnected on resume) vs. the WorkManager
/// periodic background task (see background_sync_service.dart). Kept
/// separate because a background-triggered failure and an interactive one
/// call for different next steps from the user.
enum SyncSource { interactive, background }

/// Which stage of the locate -> connect -> characteristics -> foreground
/// service -> sync -> disconnect pipeline produced this log entry. Plain
/// string constants rather than a Dart enum so a value already persisted to
/// disk from an older app version never fails to parse just because a
/// stage was renamed or added later.
class SyncStage {
  static const connect = 'connect';
  static const characteristics = 'characteristics';
  static const foregroundService = 'foreground_service';
  static const sync = 'sync';
  static const disconnect = 'disconnect';
  // Logged the instant WorkManager invokes the background task, before
  // anything else runs — proof the OS actually fired it at all, since
  // every other stage only gets logged once real work is attempted.
  static const wake = 'wake';
}

class SyncLogEntry {
  final DateTime timestamp;
  final SyncSource source;
  final bool success;
  final String stage;
  final String message;
  final int recordsSynced;

  SyncLogEntry({
    required this.timestamp,
    required this.source,
    required this.success,
    required this.stage,
    required this.message,
    this.recordsSynced = 0,
  });

  Map<String, dynamic> toJson() => {
        't': timestamp.toIso8601String(),
        'src': source.name,
        'ok': success,
        'stage': stage,
        'msg': message,
        'n': recordsSynced,
      };

  factory SyncLogEntry.fromJson(Map<String, dynamic> j) => SyncLogEntry(
        timestamp: DateTime.parse(j['t'] as String),
        source: SyncSource.values.firstWhere(
          (s) => s.name == j['src'],
          orElse: () => SyncSource.interactive,
        ),
        success: j['ok'] as bool,
        stage: j['stage'] as String? ?? 'unknown',
        message: j['msg'] as String? ?? '',
        recordsSynced: j['n'] as int? ?? 0,
      );
}

/// Persisted, capped trail of connect/sync attempts and exactly why each one
/// succeeded or failed.
///
/// Before this, every BLE failure — a real connect timeout, a foreground
/// service exception, a sync protocol error — collapsed into one generic
/// "Connection failed" shown to the user, with the actual reason going only
/// to `print()`, which is invisible outside `adb logcat`. For a background
/// sync failure (nobody watching a console at 3am) that meant no way to
/// know what went wrong after the fact.
///
/// This keeps a small history *on the phone*, capped at [_maxEntries] so it
/// can't grow unbounded over a multi-day session, that both the interactive
/// UI isolate and the WorkManager background isolate can append to and read
/// back — SharedPreferences is disk-backed and isolate-safe, unlike an
/// in-memory list, which is required here since the background task runs in
/// a separate isolate with its own empty Dart heap (see
/// background_sync_service.dart).
class SyncLogService {
  SyncLogService._();
  static final SyncLogService instance = SyncLogService._();

  static const _prefsKey = 'sync_log_v1';
  static const _maxEntries = 50;

  Future<void> record({
    required SyncSource source,
    required bool success,
    required String stage,
    required String message,
    int recordsSynced = 0,
  }) async {
    final entry = SyncLogEntry(
      timestamp: DateTime.now(),
      source: source,
      success: success,
      stage: stage,
      message: message,
      recordsSynced: recordsSynced,
    );

    // The log itself must never be able to take down a sync attempt —
    // losing a diagnostic entry is an acceptable failure, losing watch data
    // because logging threw is not. Every path below is wrapped for that
    // reason.
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await _readAll(prefs);
      existing.add(entry);

      final trimmed = existing.length > _maxEntries
          ? existing.sublist(existing.length - _maxEntries)
          : existing;

      await prefs.setString(
        _prefsKey,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // Swallow — see comment above.
    }
  }

  /// Most recent entries, newest first.
  Future<List<SyncLogEntry>> recent({int limit = 20}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await _readAll(prefs);
      final start = all.length > limit ? all.length - limit : 0;
      return all.sublist(start).reversed.toList();
    } catch (_) {
      return const [];
    }
  }

  /// The most recent failed attempt, if any — used to show the user the
  /// specific reason a connection failed instead of a generic message.
  Future<SyncLogEntry?> lastFailure() async {
    for (final e in await recent(limit: _maxEntries)) {
      if (!e.success) return e;
    }
    return null;
  }

  Future<List<SyncLogEntry>> _readAll(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SyncLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt/foreign JSON (e.g. a future app version's format) —
      // treat as empty rather than crashing every future log read.
      return [];
    }
  }
}
