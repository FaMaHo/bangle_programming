import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';

class ServerService {
  static final ServerService instance = ServerService._init();
  ServerService._init();

  final DatabaseHelper _db = DatabaseHelper.instance;

  // Get server URL from settings
  Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('server_url');
  }

  // Save server URL to settings
  Future<void> setServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
  }

  // Export data as CSV format for ML
  Future<String> exportDataToCSV({DateTime? startDate, DateTime? endDate}) async {
    final db = await _db.database;

    // Default to all data if no date range specified
    final startTimestamp = startDate?.millisecondsSinceEpoch ?? 0;
    final endTimestamp = endDate?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;

    // Query combined data (JOIN heart rate and accelerometer on timestamp)
    final result = await db.rawQuery('''
      SELECT
        hr.timestamp,
        hr.bpm,
        hr.confidence,
        a.x,
        a.y,
        a.z,
        hr.device_id
      FROM heart_rate hr
      LEFT JOIN accelerometer a ON hr.timestamp = a.timestamp
      WHERE hr.timestamp >= ? AND hr.timestamp <= ?
      ORDER BY hr.timestamp ASC
    ''', [startTimestamp, endTimestamp]);

    // Build CSV
    StringBuffer csv = StringBuffer();
    csv.writeln('timestamp,bpm,confidence,accel_x,accel_y,accel_z,device_id');

    for (var row in result) {
      csv.writeln(
        '${row['timestamp']},'
        '${row['bpm']},'
        '${row['confidence'] ?? 0},'
        '${row['x'] ?? 0},'
        '${row['y'] ?? 0},'
        '${row['z'] ?? 0},'
        '${row['device_id'] ?? 'unknown'}'
      );
    }

    return csv.toString();
  }

  // Upload data to server
  Future<UploadResult> uploadData({DateTime? startDate, DateTime? endDate}) async {
    try {
      final serverUrl = await getServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) {
        return UploadResult(
          success: false,
          message: 'Server URL not configured',
          recordsUploaded: 0,
        );
      }

      // Generate CSV data
      final csvData = await exportDataToCSV(startDate: startDate, endDate: endDate);
      final recordCount = csvData.split('\n').length - 2; // Subtract header and empty line

      if (recordCount <= 0) {
        return UploadResult(
          success: false,
          message: 'No data available to upload',
          recordsUploaded: 0,
        );
      }

      // Send to server
      final response = await http.post(
        Uri.parse('$serverUrl/upload'),
        headers: {
          'Content-Type': 'text/csv',
          'X-Device-ID': 'flutter-app',
        },
        body: csvData,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return UploadResult(
          success: true,
          message: 'Successfully uploaded $recordCount records',
          recordsUploaded: recordCount,
        );
      } else {
        return UploadResult(
          success: false,
          message: 'Server error: ${response.statusCode}',
          recordsUploaded: 0,
        );
      }
    } catch (e) {
      return UploadResult(
        success: false,
        message: 'Upload failed: $e',
        recordsUploaded: 0,
      );
    }
  }

  // Test server connection
  Future<bool> testConnection() async {
    try {
      final serverUrl = await getServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) return false;

      final response = await http.get(
        Uri.parse('$serverUrl/health'),
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // Get data statistics
  Future<DataStats> getDataStats() async {
    final db = await _db.database;

    final hrResult = await db.rawQuery('SELECT COUNT(*) as count, MIN(timestamp) as min_ts, MAX(timestamp) as max_ts FROM heart_rate');
    final accelResult = await db.rawQuery('SELECT COUNT(*) as count FROM accelerometer');

    final hrCount = (hrResult.first['count'] as int?) ?? 0;
    final accelCount = (accelResult.first['count'] as int?) ?? 0;
    final minTs = hrResult.first['min_ts'] as int?;
    final maxTs = hrResult.first['max_ts'] as int?;

    DateTime? firstReading;
    DateTime? lastReading;

    if (minTs != null) firstReading = DateTime.fromMillisecondsSinceEpoch(minTs);
    if (maxTs != null) lastReading = DateTime.fromMillisecondsSinceEpoch(maxTs);

    return DataStats(
      heartRateRecords: hrCount,
      accelerometerRecords: accelCount,
      firstReading: firstReading,
      lastReading: lastReading,
    );
  }
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
