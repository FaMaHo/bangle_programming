import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';

class ServerService {
  static final ServerService instance = ServerService._init();
  ServerService._init();

  final DatabaseHelper _db = DatabaseHelper.instance;

  // ─── Settings ────────────────────────────────────────────────────────────

  Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('server_url');
  }

  Future<void> setServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
  }

  /// Returns the anonymous patient ID that was generated at profile setup.
  /// This is safe to send — it contains no real personal information.
  Future<String> getPatientId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('patient_id') ?? 'P-UNKNOWN';
  }

  /// Returns the user's display name (stored locally only, never exported).
  Future<String> getDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('profile_display_name') ?? 'Participant';
  }

  // ─── Export ───────────────────────────────────────────────────────────────

  /// Exports the last 48 hours of data as an anonymized CSV.
  ///
  /// Columns: timestamp, hr_bpm, accel_x, accel_y, accel_z
  /// — device_id and confidence are intentionally excluded.
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
      return ExportResult(
        csv: '',
        recordCount: 0,
        isEmpty: true,
      );
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
      csv: buf.toString(),
      recordCount: rows.length,
      isEmpty: false,
    );
  }

  // ─── Upload ───────────────────────────────────────────────────────────────

  /// Exports the last 48 hours of anonymized data and uploads it to the server.
  ///
  /// Headers sent:
  ///   X-Patient-ID  — anonymous code (e.g. P-A3F2-1990)
  ///   X-Session-ID  — auto-generated from upload timestamp
  ///
  /// Headers NOT sent:
  ///   X-Device-ID   — removed to protect device identity
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

      final response = await http.post(
        Uri.parse('$serverUrl/upload'),
        headers: {
          'Content-Type': 'text/csv',
          'X-Patient-ID': patientId,
          'X-Session-ID': sessionId,
        },
        body: export.csv,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return UploadResult(
          success: true,
          message: 'Uploaded ${export.recordCount} records successfully.',
          recordsUploaded: export.recordCount,
        );
      } else {
        return UploadResult(
          success: false,
          message: 'Server returned an error (${response.statusCode}). '
              'Please check your connection and try again.',
          recordsUploaded: 0,
        );
      }
    } catch (e) {
      return UploadResult(
        success: false,
        message: 'Could not reach the server. Make sure you are on the same '
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

  ExportResult({
    required this.csv,
    required this.recordCount,
    required this.isEmpty,
  });
}

class UploadResult {
  final bool success;
  final String message;
  final int recordsUploaded;

  UploadResult({
    required this.success,
    required this.message,
    required this.recordsUploaded,
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