import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';

class ServerService {
  static final ServerService instance = ServerService._init();
  ServerService._init();

  final DatabaseHelper _db = DatabaseHelper.instance;

  static const _autoUploadIntervalHours = 6;

  // ─── Settings ────────────────────────────────────────────────────────────

  Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('server_url');
  }

  Future<void> setServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
  }

  Future<String> getPatientId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('patient_id') ?? 'P-UNKNOWN';
  }

  Future<String> getDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('profile_display_name') ?? 'Participant';
  }

  // ─── Last upload tracking ─────────────────────────────────────────────────

  Future<DateTime?> getLastUploadTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt('last_upload_time');
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  Future<void> _saveLastUploadTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        'last_upload_time', DateTime.now().millisecondsSinceEpoch);
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
    if (lastUpload == null) return false; // first upload must be manual

    final hoursSinceLast = DateTime.now().difference(lastUpload).inHours;
    if (hoursSinceLast < _autoUploadIntervalHours) return false;

    final stats = await getDataStats();
    return stats.heartRateRecords > 0;
  }

  // ─── mDNS Discovery ───────────────────────────────────────────────────────

  /// Scans the local network for a PulseWatch server announced via mDNS
  /// (_pulsewatch._tcp.local). Times out after 5 seconds.
  /// Returns the server base URL (e.g. http://192.168.1.42:5001) or null.
  Future<String?> discoverServerViaMdns() async {
    final completer = Completer<String?>();
    final client = MDnsClient();

    try {
      await client.start();

      // Timeout: give up after 5 s if nothing found
      Timer(const Duration(seconds: 5), () {
        if (!completer.isCompleted) completer.complete(null);
      });

      client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_pulsewatch._tcp.local'),
          )
          .listen((ptr) {
        client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
            )
            .listen((srv) {
          client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
              )
              .listen((ip) {
            if (!completer.isCompleted) {
              completer
                  .complete('http://${ip.address.address}:${srv.port}');
            }
          });
        });
      });

      return await completer.future;
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
      return null;
    } finally {
      client.stop();
    }
  }

  // ─── Smart upload (hybrid) ────────────────────────────────────────────────

  /// Hybrid upload strategy:
  ///   1. Try the stored server URL directly.
  ///   2. If unreachable, scan the local network via mDNS and update the
  ///      stored URL if a server is found.
  ///   3. If still unreachable, return a graceful failure with needsRescan=true
  ///      so the UI can prompt the user to scan a new QR code.
  Future<UploadResult> smartUpload() async {
    // Step 1 — stored URL
    final stored = await getServerUrl();
    if (stored != null && stored.isNotEmpty) {
      if (await testConnection()) return uploadData();
    }

    // Step 2 — mDNS discovery
    final discovered = await discoverServerViaMdns();
    if (discovered != null) {
      await setServerUrl(discovered); // keep it for next time
      if (await testConnection()) return uploadData();
    }

    // Step 3 — give up gracefully
    return UploadResult(
      success: false,
      message: 'Server not reachable.',
      recordsUploaded: 0,
      needsRescan: true,
    );
  }

  // ─── Export ───────────────────────────────────────────────────────────────

  /// Exports the last 48 hours of data as an anonymized CSV.
  /// Columns: timestamp, hr_bpm, accel_x, accel_y, accel_z
  Future<ExportResult> exportAnonymizedCSV() async {
    final db = await _db.database;

    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 48))
        .millisecondsSinceEpoch;

    final rows = await db.rawQuery('''
      SELECT
        hr.timestamp,
        hr.bpm        AS hr_bpm,
        a.x           AS accel_x,
        a.y           AS accel_y,
        a.z           AS accel_z
      FROM heart_rate hr
      LEFT JOIN accelerometer a
        ON abs(hr.timestamp - a.timestamp) < 500
      WHERE hr.timestamp >= ?
      ORDER BY hr.timestamp ASC
    ''', [cutoff]);

    if (rows.isEmpty) {
      return ExportResult(csv: '', recordCount: 0, isEmpty: true);
    }

    final buf = StringBuffer();
    buf.writeln('timestamp,hr_bpm,accel_x,accel_y,accel_z');
    for (final row in rows) {
      buf.writeln(
        '${row['timestamp']},'
        '${row['hr_bpm']},'
        '${row['accel_x'] ?? 0},'
        '${row['accel_y'] ?? 0},'
        '${row['accel_z'] ?? 0}',
      );
    }

    return ExportResult(
        csv: buf.toString(), recordCount: rows.length, isEmpty: false);
  }

  // ─── Upload ───────────────────────────────────────────────────────────────

  /// Exports and uploads the last 48 hours of anonymized data.
  /// Saves [lastUploadTime] on success so auto-upload can track the interval.
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
          message: 'No data recorded in the last 48 hours.',
          recordsUploaded: 0,
        );
      }

      final patientId = await getPatientId();
      final sessionId = 'session-${DateTime.now().millisecondsSinceEpoch}';

      final response = await http
          .post(
            Uri.parse('$serverUrl/upload'),
            headers: {
              'Content-Type': 'text/csv',
              'X-Patient-ID': patientId,
              'X-Session-ID': sessionId,
            },
            body: export.csv,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        await _saveLastUploadTime();
        return UploadResult(
          success: true,
          message: 'Uploaded ${export.recordCount} records successfully.',
          recordsUploaded: export.recordCount,
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

  // ─── Stats ────────────────────────────────────────────────────────────────

  Future<DataStats> getDataStats() async {
    final db = await _db.database;

    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 48))
        .millisecondsSinceEpoch;

    final hrResult = await db.rawQuery(
      'SELECT COUNT(*) as count, MIN(timestamp) as min_ts, MAX(timestamp) as max_ts '
      'FROM heart_rate WHERE timestamp >= ?',
      [cutoff],
    );
    final accelResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM accelerometer WHERE timestamp >= ?',
      [cutoff],
    );

    final hrCount = (hrResult.first['count'] as int?) ?? 0;
    final accelCount = (accelResult.first['count'] as int?) ?? 0;
    final minTs = hrResult.first['min_ts'] as int?;
    final maxTs = hrResult.first['max_ts'] as int?;

    return DataStats(
      heartRateRecords: hrCount,
      accelerometerRecords: accelCount,
      firstReading: minTs != null
          ? DateTime.fromMillisecondsSinceEpoch(minTs)
          : null,
      lastReading: maxTs != null
          ? DateTime.fromMillisecondsSinceEpoch(maxTs)
          : null,
    );
  }
}

// ─── Models ───────────────────────────────────────────────────────────────────

class ExportResult {
  final String csv;
  final int recordCount;
  final bool isEmpty;

  ExportResult(
      {required this.csv,
      required this.recordCount,
      required this.isEmpty});
}

class UploadResult {
  final bool success;
  final String message;
  final int recordsUploaded;
  final bool needsRescan;

  UploadResult({
    required this.success,
    required this.message,
    required this.recordsUploaded,
    this.needsRescan = false,
  });
}

class DataStats {
  final int heartRateRecords;
  final int accelerometerRecords;
  final DateTime? firstReading;
  final DateTime? lastReading;

  DataStats({
    required this.heartRateRecords,
    required this.accelerometerRecords,
    this.firstReading,
    this.lastReading,
  });
}
