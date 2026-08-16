import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'database_helper.dart';

class ServerService {
  static final ServerService instance = ServerService._init();
  ServerService._init();

  final DatabaseHelper _db = DatabaseHelper.instance;

  static const _autoUploadIntervalHours = 6;

  // Production backend — always-on VPS with a real domain and HTTPS.
  // Works from any network (including China), no same-WiFi pairing or
  // Tailscale required on the patient's phone.
  static const _defaultServerUrl = 'https://pulsana.org';

  // ─── Settings ────────────────────────────────────────────────────────────

  Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('server_url');
    return (stored != null && stored.isNotEmpty) ? stored : _defaultServerUrl;
  }

  Future<void> setServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
  }

  Future<String> getPatientId() async {
    return await AuthService.instance.getPatientId() ?? 'P-UNKNOWN';
  }

  Future<String> getDisplayName() async {
    return await AuthService.instance.getUsername() ?? 'Participant';
  }

  // ─── Last upload tracking ─────────────────────────────────────────────────

  Future<DateTime?> getLastUploadTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(await AuthService.instance.scopedKey('last_upload_time'));
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  // Takes the timestamp of the last row actually included in the upload,
  // not DateTime.now() — the export query runs before the network POST,
  // so a reading inserted during that round-trip would already be past
  // "now" by the time this saves, and never appear in an export again
  // (the next delta starts *after* whatever's saved here). Anchoring to
  // what was actually sent means the next delta always picks up exactly
  // where this one left off, no gap and no re-send.
  Future<void> _saveLastUploadTime(DateTime uploadedThrough) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        await AuthService.instance.scopedKey('last_upload_time'), uploadedThrough.millisecondsSinceEpoch);
    // A successful upload clears whatever backlog was accumulating —
    // see checkUploadHealth below.
    await prefs.remove(await AuthService.instance.scopedKey('pending_since'));
  }

  // ─── Auto-upload eligibility ──────────────────────────────────────────────

  /// Returns true when all conditions for a silent auto-upload are met:
  ///  - Server URL has been configured
  ///  - At least one manual upload has completed before (lastUploadTime != null)
  ///  - More than [_autoUploadIntervalHours] hours have passed since last upload
  ///  - There is actually data to send
  Future<bool> shouldAutoUpload() async {
    final serverUrl = await getServerUrl();
    if (serverUrl == null || serverUrl.isEmpty) return false;

    final lastUpload = await getLastUploadTime();
    if (lastUpload != null) {
      final hoursSinceLast = DateTime.now().difference(lastUpload).inHours;
      if (hoursSinceLast < _autoUploadIntervalHours) return false;
    }

    return await getPendingUploadCount() > 0;
  }

  // ─── Upload health ─────────────────────────────────────────────────────────

  static const _backlogEscalationHours = 12;

  /// How long data has been sitting locally without reaching the server,
  /// and whether the server is even reachable right now — the two signals
  /// that decide whether the app needs to bother the user (a passive
  /// "check your connection" banner/notification, or an active "upload
  /// manually" popup + notification) instead of quietly retrying on its
  /// own, which is what it does the rest of the time.
  Future<UploadHealth> checkUploadHealth() async {
    final lastReading = await _db.getLastReadingTime();
    if (lastReading == null) return UploadHealth.ok;

    final lastUpload = await getLastUploadTime();
    final hasPending = lastUpload == null || lastReading.isAfter(lastUpload);

    final prefs = await SharedPreferences.getInstance();
    final pendingSinceKey = await AuthService.instance.scopedKey('pending_since');
    if (!hasPending) {
      await prefs.remove(pendingSinceKey);
      return UploadHealth.ok;
    }

    // Tracks when the *current* unsynced streak started — not just "last
    // successful upload" — so a run of failures is measured from when
    // trouble actually began, not reset by new readings arriving in the
    // meantime.
    final pendingSinceMs = prefs.getInt(pendingSinceKey);
    final DateTime pendingSince;
    if (pendingSinceMs == null) {
      pendingSince = DateTime.now();
      await prefs.setInt(pendingSinceKey, pendingSince.millisecondsSinceEpoch);
    } else {
      pendingSince = DateTime.fromMillisecondsSinceEpoch(pendingSinceMs);
    }

    if (!await testConnection()) return UploadHealth.noConnection;

    final hoursSincePending = DateTime.now().difference(pendingSince).inHours;
    return hoursSincePending >= _backlogEscalationHours
        ? UploadHealth.backlogRisk
        : UploadHealth.ok;
  }

  /// Cooldown for the backlog-risk popup specifically (separate from the
  /// notification's own cooldown in NotificationService) — re-nag every
  /// few hours while the problem persists, not on every single app open.
  Future<bool> shouldShowBacklogPopup() async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(await AuthService.instance.scopedKey('backlog_popup_last_shown_ms'));
    if (lastMs == null) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
    return DateTime.now().difference(last) >= const Duration(hours: 6);
  }

  Future<void> markBacklogPopupShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        await AuthService.instance.scopedKey('backlog_popup_last_shown_ms'), DateTime.now().millisecondsSinceEpoch);
  }

  // ─── Smart upload ─────────────────────────────────────────────────────────

  /// Tries the configured server URL (the fixed production domain unless
  /// overridden) and uploads if reachable. No local-network discovery is
  /// needed now that the backend is an always-on public domain rather than
  /// a same-WiFi researcher's laptop.
  Future<UploadResult> smartUpload() async {
    final stored = await getServerUrl();
    if (stored != null && stored.isNotEmpty) {
      if (await testConnection()) return uploadData();
    }

    return UploadResult(
      success: false,
      message: 'Server not reachable.',
      recordsUploaded: 0,
      needsRescan: true,
    );
  }

  // ─── Export ───────────────────────────────────────────────────────────────

  /// The boundary the next upload's delta starts after — the last
  /// successful upload's data cutoff, or 48h ago for a first-ever upload.
  /// Shared by exportAnonymizedCSV and getPendingUploadCount so the count
  /// shown before uploading always matches what actually gets sent.
  Future<int> _deltaCutoffMs() async {
    final lastUpload = await getLastUploadTime();
    return (lastUpload ?? DateTime.now().subtract(const Duration(hours: 48)))
        .millisecondsSinceEpoch;
  }

  /// Cheap count of readings recorded since the last successful upload —
  /// for showing "N not yet uploaded" in the UI without paying for a full
  /// CSV export just to display a number.
  Future<int> getPendingUploadCount() async {
    final db = await _db.database;
    final cutoff = await _deltaCutoffMs();
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM heart_rate WHERE timestamp > ?',
      [cutoff],
    );
    return (result.first['count'] as int?) ?? 0;
  }

  /// Exports everything since the last successful upload (or the last 48
  /// hours, for a first-ever upload) as an anonymized CSV. Columns:
  /// timestamp, hr_bpm, rr_intervals_ms, accel_x, accel_y, accel_z
  ///
  /// This must stay a delta, not a fixed "last 48 hours" snapshot — the
  /// backend's /upload endpoint just writes each upload as its own new
  /// file with no dedup against previous uploads (see pulsewatch_backend/
  /// app.py), so re-sending the same window on every auto-upload cycle
  /// would leave the server with heavily overlapping, duplicated data by
  /// the end of a session instead of one clean record of it.
  Future<ExportResult> exportAnonymizedCSV() async {
    final db = await _db.database;

    final cutoff = await _deltaCutoffMs();

    // The join condition must stay sargable — abs(hr.timestamp - a.timestamp)
    // < 500 can't use idx_accel_timestamp, so SQLite falls back to a nested
    // scan of the whole accelerometer table per heart_rate row. At a real
    // 48h session's row counts that's on the order of N*M comparisons and
    // can run for minutes while holding the connection's lock, starving
    // every other read/write on the app (this is what caused Insights/Device
    // to look "frozen" — not a deadlock, a query stuck for a very long time).
    // Rewriting as a BETWEEN range lets it use the existing timestamp index.
    final rows = await db.rawQuery('''
      SELECT
        hr.timestamp,
        hr.bpm        AS hr_bpm,
        COALESCE(hr.rr_interval_ms, 0) AS rr_intervals_ms,
        a.x           AS accel_x,
        a.y           AS accel_y,
        a.z           AS accel_z
      FROM heart_rate hr
      LEFT JOIN accelerometer a
        ON a.timestamp BETWEEN hr.timestamp - 500 AND hr.timestamp + 500
      WHERE hr.timestamp > ? AND hr.timestamp <= ?
      ORDER BY hr.timestamp ASC
    ''', [cutoff, DatabaseHelper.maxValidTimestampMs]);

    if (rows.isEmpty) {
      return ExportResult(csv: '', recordCount: 0, isEmpty: true);
    }

    final buf = StringBuffer();
    buf.writeln('timestamp,hr_bpm,rr_intervals_ms,accel_x,accel_y,accel_z');
    for (final row in rows) {
      buf.writeln(
        '${row['timestamp']},'
        '${row['hr_bpm']},'
        '${row['rr_intervals_ms']},'
        '${row['accel_x'] ?? 0},'
        '${row['accel_y'] ?? 0},'
        '${row['accel_z'] ?? 0}',
      );
    }

    return ExportResult(
      csv: buf.toString(),
      recordCount: rows.length,
      isEmpty: false,
      // rows are ORDER BY hr.timestamp ASC, so the last row carries the
      // max heart_rate timestamp actually included in this export.
      latestTimestamp: DateTime.fromMillisecondsSinceEpoch(rows.last['timestamp'] as int),
    );
  }

  // ─── Upload ───────────────────────────────────────────────────────────────

  /// Exports and uploads everything recorded since the last successful
  /// upload. Saves [lastUploadTime] (from the export's own latest included
  /// row, not the wall clock) on success so the next call picks up exactly
  /// where this one left off.
  Future<UploadResult> uploadData() async {
    try {
      final serverUrl = await getServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) {
        return UploadResult(
          success: false,
          message: 'Server URL not configured. Please enter it below.',
          recordsUploaded: 0,
        );
      }

      final export = await exportAnonymizedCSV();
      if (export.isEmpty) {
        return UploadResult(
          success: false,
          message: 'No new data to upload.',
          recordsUploaded: 0,
        );
      }

      final sessionId = 'session-${DateTime.now().millisecondsSinceEpoch}';

      Future<http.Response> doUpload() async {
        final authHeader = await AuthService.instance.authHeader();
        return http
            .post(
              Uri.parse('$serverUrl/upload'),
              headers: {
                'Content-Type': 'text/csv',
                'X-Session-ID': sessionId,
                'X-Device-ID': 'flutter-app',
                ...authHeader,
              },
              body: export.csv,
            )
            .timeout(const Duration(seconds: 30));
      }

      var response = await doUpload();

      // Access token expired mid-session — refresh once and retry.
      if (response.statusCode == 401) {
        final refreshed = await AuthService.instance.refreshAccessToken();
        if (refreshed != null) {
          response = await doUpload();
        }
      }

      if (response.statusCode == 200) {
        await _saveLastUploadTime(export.latestTimestamp!);
        return UploadResult(
          success: true,
          message: 'Uploaded ${export.recordCount} record${export.recordCount == 1 ? '' : 's'} successfully.',
          recordsUploaded: export.recordCount,
        );
      } else if (response.statusCode == 401) {
        return UploadResult(
          success: false,
          message: 'Your session has expired. Please log in again.',
          recordsUploaded: 0,
          needsLogin: true,
        );
      } else {
        return UploadResult(
          success: false,
          message:
              'Server returned an error (${response.statusCode}). '
              'Please check your connection and try again.',
          recordsUploaded: 0,
        );
      }
    } on SocketException {
      // Thrown when the OS can't even open a connection — no network path
      // to anywhere, as opposed to a network that's up but a server that
      // isn't answering (TimeoutException below).
      return UploadResult(
        success: false,
        message: "No internet connection. Check your phone's connection and try again.",
        recordsUploaded: 0,
      );
    } on TimeoutException {
      return UploadResult(
        success: false,
        message: "Couldn't reach the server — it may be down. Try again shortly.",
        recordsUploaded: 0,
      );
    } catch (e) {
      return UploadResult(
        success: false,
        message:
            'Could not reach the server. Make sure you are on the same '
            'network and the URL is correct.',
        recordsUploaded: 0,
      );
    }
  }

  // ─── Connection test ──────────────────────────────────────────────────────

  Future<bool> testConnection() async {
    try {
      final serverUrl = await getServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) return false;
      final response = await http
          .get(Uri.parse('$serverUrl/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

}

// ─── Models ───────────────────────────────────────────────────────────────────

/// ok: nothing pending, or pending but still well within the normal
/// auto-upload cadence. noConnection: there's pending data and the server
/// can't be reached at all. backlogRisk: there's pending data, the server
/// IS reachable, but it still hasn't gone through in over
/// [ServerService._backlogEscalationHours] — something other than a
/// simple connectivity blip is wrong.
enum UploadHealth { ok, noConnection, backlogRisk }

class ExportResult {
  final String csv;
  final int recordCount;
  final bool isEmpty;
  // Timestamp of the last row actually included — null when isEmpty.
  // See _saveLastUploadTime's doc comment for why this, not DateTime.now(),
  // anchors the next delta.
  final DateTime? latestTimestamp;

  ExportResult(
      {required this.csv,
      required this.recordCount,
      required this.isEmpty,
      this.latestTimestamp});
}

class UploadResult {
  final bool success;
  final String message;
  final int recordsUploaded;
  final bool needsRescan;
  final bool needsLogin;

  UploadResult({
    required this.success,
    required this.message,
    required this.recordsUploaded,
    this.needsRescan = false,
    this.needsLogin = false,
  });
}

