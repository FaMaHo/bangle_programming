import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('pulsewatch.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add confidence column if it doesn't exist (migration from v1 to v2)
      await db.execute('ALTER TABLE heart_rate ADD COLUMN confidence INTEGER');
    }
  }

  Future<void> _createDB(Database db, int version) async {
    // Heart rate readings table
    await db.execute('''
      CREATE TABLE heart_rate (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        bpm INTEGER NOT NULL,
        confidence INTEGER,
        device_id TEXT
      )
    ''');

    // Accelerometer readings table
    await db.execute('''
      CREATE TABLE accelerometer (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        x INTEGER NOT NULL,
        y INTEGER NOT NULL,
        z INTEGER NOT NULL,
        device_id TEXT
      )
    ''');

    // Sessions table (connection sessions)
    await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        start_time INTEGER NOT NULL,
        end_time INTEGER,
        total_readings INTEGER DEFAULT 0
      )
    ''');

    // Create indexes for faster queries
    await db.execute('CREATE INDEX idx_hr_timestamp ON heart_rate(timestamp)');
    await db.execute('CREATE INDEX idx_accel_timestamp ON accelerometer(timestamp)');
  }

  // Insert heart rate reading
  Future<int> insertHeartRate(int bpm, String? deviceId) async {
    final db = await database;
    return await db.insert('heart_rate', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'bpm': bpm,
      'device_id': deviceId,
    });
  }

  // Insert heart rate with specific timestamp and confidence (for CSV data from watch)
  Future<int> insertHeartRateWithTimestamp(int timestamp, int bpm, int confidence, String? deviceId) async {
    final db = await database;
    return await db.insert('heart_rate', {
      'timestamp': timestamp,
      'bpm': bpm,
      'confidence': confidence,
      'device_id': deviceId,
    });
  }

  // Insert accelerometer reading
  Future<int> insertAccelerometer(int x, int y, int z, String? deviceId) async {
    final db = await database;
    return await db.insert('accelerometer', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'x': x,
      'y': y,
      'z': z,
      'device_id': deviceId,
    });
  }

  // Insert accelerometer with specific timestamp (for CSV data from watch)
  Future<int> insertAccelerometerWithTimestamp(int timestamp, int x, int y, int z, String? deviceId) async {
    final db = await database;
    return await db.insert('accelerometer', {
      'timestamp': timestamp,
      'x': x,
      'y': y,
      'z': z,
      'device_id': deviceId,
    });
  }

  // Get heart rate for today
  Future<List<Map<String, dynamic>>> getTodayHeartRate() async {
    final db = await database;
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;

    return await db.query(
      'heart_rate',
      where: 'timestamp >= ?',
      whereArgs: [startOfDay],
      orderBy: 'timestamp DESC',
    );
  }

  // Get heart rate statistics for today
  Future<Map<String, dynamic>> getTodayHRStats() async {
    final db = await database;
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;

    final result = await db.rawQuery('''
      SELECT 
        MIN(bpm) as minHR,
        MAX(bpm) as maxHR,
        AVG(bpm) as avgHR,
        COUNT(*) as count
      FROM heart_rate
      WHERE timestamp >= ?
    ''', [startOfDay]);

    return result.first;
  }

  // Get last N heart rate readings
  Future<List<Map<String, dynamic>>> getRecentHeartRate(int limit) async {
    final db = await database;
    return await db.query(
      'heart_rate',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }

  // Start a new session
  Future<int> startSession(String deviceId) async {
    final db = await database;
    return await db.insert('sessions', {
      'device_id': deviceId,
      'start_time': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // End current session
  Future<void> endSession(int sessionId, int totalReadings) async {
    final db = await database;
    await db.update(
      'sessions',
      {
        'end_time': DateTime.now().millisecondsSinceEpoch,
        'total_readings': totalReadings,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  // Get total readings count
  Future<int> getTotalReadings() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM heart_rate');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // Clear old data (keep last 7 days)
  Future<void> cleanOldData() async {
    final db = await database;
    final sevenDaysAgo = DateTime.now().subtract(Duration(days: 7)).millisecondsSinceEpoch;
    
    await db.delete('heart_rate', where: 'timestamp < ?', whereArgs: [sevenDaysAgo]);
    await db.delete('accelerometer', where: 'timestamp < ?', whereArgs: [sevenDaysAgo]);
  }

  // Export data to CSV format
  Future<String> exportToCSV({int? lastNDays}) async {
    final db = await database;
    
    String whereClause = '';
    List<dynamic> whereArgs = [];
    
    if (lastNDays != null) {
      final startTime = DateTime.now()
          .subtract(Duration(days: lastNDays))
          .millisecondsSinceEpoch;
      whereClause = 'WHERE h.timestamp >= ?';
      whereArgs = [startTime];
    }
    
    // Get combined heart rate and accelerometer data
    final result = await db.rawQuery('''
      SELECT 
        h.timestamp,
        h.bpm,
        a.x,
        a.y,
        a.z,
        h.device_id
      FROM heart_rate h
      LEFT JOIN accelerometer a ON abs(h.timestamp - a.timestamp) < 100
      $whereClause
      ORDER BY h.timestamp ASC
    ''', whereArgs);
    
    // Build CSV
    StringBuffer csv = StringBuffer();
    csv.writeln('timestamp,datetime,bpm,accel_x,accel_y,accel_z,device_id');
    
    for (var row in result) {
      final timestamp = row['timestamp'] as int;
      final datetime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final bpm = row['bpm'];
      final x = row['x'] ?? '';
      final y = row['y'] ?? '';
      final z = row['z'] ?? '';
      final deviceId = row['device_id'] ?? '';
      
      csv.writeln('$timestamp,$datetime,$bpm,$x,$y,$z,$deviceId');
    }
    
    return csv.toString();
  }
  
  // Get database statistics
  Future<Map<String, dynamic>> getDatabaseStats() async {
    final db = await database;
    
    final hrCount = await db.rawQuery('SELECT COUNT(*) as count FROM heart_rate');
    final accelCount = await db.rawQuery('SELECT COUNT(*) as count FROM accelerometer');
    
    final firstHR = await db.rawQuery('SELECT MIN(timestamp) as first FROM heart_rate');
    final lastHR = await db.rawQuery('SELECT MAX(timestamp) as last FROM heart_rate');
    
    int? firstTimestamp = firstHR.first['first'] as int?;
    int? lastTimestamp = lastHR.first['last'] as int?;
    
    return {
      'total_hr_readings': Sqflite.firstIntValue(hrCount) ?? 0,
      'total_accel_readings': Sqflite.firstIntValue(accelCount) ?? 0,
      'first_reading': firstTimestamp != null 
          ? DateTime.fromMillisecondsSinceEpoch(firstTimestamp).toString()
          : null,
      'last_reading': lastTimestamp != null
          ? DateTime.fromMillisecondsSinceEpoch(lastTimestamp).toString()
          : null,
      'duration_hours': firstTimestamp != null && lastTimestamp != null
          ? (lastTimestamp - firstTimestamp) / (1000 * 60 * 60)
          : 0,
    };
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}