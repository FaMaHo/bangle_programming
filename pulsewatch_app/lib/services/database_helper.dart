import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static String? _activeUserId;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB(_dbFileName());
    return _database!;
  }

  String _dbFileName() {
    final id = _activeUserId;
    if (id == null || id.isEmpty) return 'pulsewatch.db';
    final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'pulsewatch_$safeId.db';
  }

  /// Points every call below at [patientId]'s own local database file
  /// instead of one file shared by every account that's ever logged into
  /// this device — otherwise a second test account (or a second real
  /// participant sharing a phone) silently sees the previous account's
  /// heart-rate and accelerometer rows, which is exactly the bug a second
  /// signup surfaced. Call this once the active user is known: right after
  /// login/enrollment succeeds, and again on cold start once AuthService
  /// confirms an existing session (see AuthService.switchActiveUser).
  ///
  /// Idempotent for the same id. Switching to a different id (or to null,
  /// on logout) closes whatever database is currently open so the next
  /// access opens the right file fresh — nothing is deleted either way,
  /// each account's data just lives in its own file.
  Future<void> switchUser(String? patientId) async {
    if (_activeUserId == patientId) return;
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
    _activeUserId = patientId;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    final db = await openDatabase(
      path,
      version: 4,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );

    // The foreground app and the periodic background sync task
    // (background_sync_service.dart) run in separate isolates, each with
    // their own connection to this same file, and can genuinely write
    // around the same moment during a long session. WAL lets one side
    // read/write without blocking as aggressively as SQLite's default
    // rollback-journal mode, and recovers cleanly from an abrupt process
    // kill instead of needing hot-journal rollback on next open.
    //
    // Both PRAGMAs return their new value as a result row, and Android's
    // SQLiteDatabase.execSQL (what db.execute maps to) rejects any SQL
    // that returns results, so these must go through rawQuery instead.
    await db.rawQuery('PRAGMA journal_mode=WAL');
    // Per-connection, so this has to be set on every open (unlike
    // journal_mode, which is stored in the file itself): if the other
    // isolate's connection IS mid-write, wait and retry at the SQLite
    // level for up to 15s instead of failing/surfacing "database is
    // locked" immediately.
    await db.rawQuery('PRAGMA busy_timeout=15000');

    return db;
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add confidence column if it doesn't exist (migration from v1 to v2)
      await db.execute('ALTER TABLE heart_rate ADD COLUMN confidence INTEGER');
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE heart_rate ADD COLUMN rr_interval_ms INTEGER'
      );
    }
    if (oldVersion < 4) {
      // Live streaming and file sync both insert into these tables from
      // the same underlying watch samples, with nothing previously
      // preventing the same (timestamp, device) sample from landing twice
      // — e.g. a sample already captured live, whose source file on the
      // watch later also gets synced because it wasn't erased in time.
      // report_service.dart averages every row in a window with no
      // dedup, so a duplicate silently double-weights that instant in the
      // computed HRV features and the final risk score, with no visible
      // symptom. A UNIQUE index makes a duplicate an INSERT conflict
      // instead, resolved as ConflictAlgorithm.ignore at every insert call
      // site below — existing duplicate rows are removed first since
      // CREATE UNIQUE INDEX fails outright if any already exist.
      await db.execute('''
        DELETE FROM heart_rate WHERE id NOT IN (
          SELECT MIN(id) FROM heart_rate GROUP BY timestamp, device_id
        )
      ''');
      await db.execute('''
        DELETE FROM accelerometer WHERE id NOT IN (
          SELECT MIN(id) FROM accelerometer GROUP BY timestamp, device_id
        )
      ''');
      await db.execute(
        'CREATE UNIQUE INDEX idx_hr_unique ON heart_rate(timestamp, device_id)',
      );
      await db.execute(
        'CREATE UNIQUE INDEX idx_accel_unique ON accelerometer(timestamp, device_id)',
      );
    }
  }

  Future<void> _createDB(Database db, int version) async {
    // Heart rate readings table
    await db.execute('''
      CREATE TABLE heart_rate (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        bpm INTEGER NOT NULL,
        rr_interval_ms INTEGER,
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

    // See _upgradeDB's v4 migration for why these exist: prevents the same
    // watch sample from being inserted twice (once live, once via a later
    // file sync of the same period) from silently double-weighting the AI
    // risk score.
    await db.execute(
      'CREATE UNIQUE INDEX idx_hr_unique ON heart_rate(timestamp, device_id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_accel_unique ON accelerometer(timestamp, device_id)',
    );
  }

  // Insert heart rate reading
  Future<int> insertHeartRate(int bpm, String? deviceId) async {
    final db = await database;
    return await db.insert(
      'heart_rate',
      {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'bpm': bpm,
        'device_id': deviceId,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // Insert heart rate with specific timestamp and confidence (for CSV data from watch)
  Future<int> insertHeartRateWithTimestamp(int timestamp, int bpm, int rrIntervalMs, int confidence, String? deviceId) async {
    final db = await database;
    return await db.insert(
      'heart_rate',
      {
        'timestamp': timestamp,
        'bpm': bpm,
        'rr_interval_ms': rrIntervalMs,
        'confidence': confidence,
        'device_id': deviceId,
      },
      // Same (timestamp, device_id) landing twice — once from live
      // streaming, once from a later file sync covering the same period —
      // is exactly the duplication this index exists to block; silently
      // dropping the second insert is correct here; see the v4 migration.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // Insert accelerometer reading
  Future<int> insertAccelerometer(int x, int y, int z, String? deviceId) async {
    final db = await database;
    return await db.insert(
      'accelerometer',
      {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'x': x,
        'y': y,
        'z': z,
        'device_id': deviceId,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // Insert accelerometer with specific timestamp (for CSV data from watch)
  Future<int> insertAccelerometerWithTimestamp(int timestamp, int x, int y, int z, String? deviceId) async {
    final db = await database;
    return await db.insert(
      'accelerometer',
      {
        'timestamp': timestamp,
        'x': x,
        'y': y,
        'z': z,
        'device_id': deviceId,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Inserts a whole synced-file's worth of rows as one transaction —
  /// used by BleService._processFileData instead of calling
  /// insertHeartRateWithTimestamp/insertAccelerometerWithTimestamp per
  /// row. sqflite implicitly wraps every individual insert() in its own
  /// commit+fsync, so a file with hundreds or thousands of buffered rows
  /// used to mean that many separate write-lock acquisitions in a row —
  /// long enough, often enough, to collide with the periodic background
  /// sync task (a separate isolate, its own connection to this same
  /// file) and leave the database stuck "locked" during a real multi-hour
  /// session. One transaction per file removes almost all of that window.
  Future<void> insertSyncedRows({
    required List<Map<String, dynamic>> heartRateRows,
    required List<Map<String, dynamic>> accelRows,
  }) async {
    final db = await database;
    final batch = db.batch();
    for (final row in heartRateRows) {
      batch.insert('heart_rate', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final row in accelRows) {
      batch.insert('accelerometer', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
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

  // Get every HR+accel row (joined, oldest-first) since cutoffMillis — used
  // for full-session inference once the 48h collection goal is reached.
  //
  // Joins on an exact timestamp match rather than a fuzzy `abs(diff) < 500`
  // range: the firmware (bangle/lib.js onHRM) stamps one HR sample and one
  // accel sample per tick with the *same* integer timestamp, and
  // ble_service.dart inserts both rows with that identical value — so an
  // exact match is correct for real data, and unlike a range comparison it
  // can use idx_hr_timestamp/idx_accel_timestamp instead of falling back to
  // a full nested-loop join. That distinction matters a lot at 48h scale:
  // a range join over ~170k rows on each side is an O(n*m) scan (tens of
  // billions of comparisons) that never finishes in practice; the indexed
  // equality join is O(n log m).
  Future<List<Map<String, dynamic>>> getHRWithAccelSince(int cutoffMillis) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT h.timestamp, h.bpm,
             COALESCE(h.rr_interval_ms, 0) AS rr,
             COALESCE(a.x, 0) AS x,
             COALESCE(a.y, 0) AS y,
             COALESCE(a.z, 0) AS z
      FROM heart_rate h
      LEFT JOIN accelerometer a
        ON a.timestamp = h.timestamp
      WHERE h.timestamp >= ?
      ORDER BY h.timestamp ASC
    ''', [cutoffMillis]);
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
  
  Future<List<int>> getNocturnalHR() async {
    final db = await database;
    final now = DateTime.now();
    final DateTime windowStart;
    final DateTime windowEnd;
    if (now.hour < 6) {
      final yesterday = now.subtract(const Duration(days: 1));
      windowStart = DateTime(yesterday.year, yesterday.month, yesterday.day);
      windowEnd   = DateTime(yesterday.year, yesterday.month, yesterday.day, 6);
    } else {
      windowStart = DateTime(now.year, now.month, now.day);
      windowEnd   = DateTime(now.year, now.month, now.day, 6);
    }
    final result = await db.query(
      'heart_rate',
      columns: ['bpm'],
      where: 'timestamp >= ? AND timestamp < ?',
      whereArgs: [windowStart.millisecondsSinceEpoch, windowEnd.millisecondsSinceEpoch],
      orderBy: 'timestamp ASC',
    );
    return result.map((r) => r['bpm'] as int).toList();
  }

  Future<List<double>> getHourlyMeanHR(int hours) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(hours: hours))
        .millisecondsSinceEpoch;
    final result = await db.rawQuery(
      'SELECT (timestamp / 3600000) AS hour_bucket, AVG(bpm) AS mean_bpm '
      'FROM heart_rate WHERE timestamp >= ? '
      'GROUP BY hour_bucket ORDER BY hour_bucket ASC',
      [cutoff],
    );
    return result.map((r) => (r['mean_bpm'] as num).toDouble()).toList();
  }

  /// Per-hour mean BPM and mean signal confidence for the last [hours]
  /// hours — the Insights screen's wear-time timeline is built from this.
  /// The trend chart itself uses getHrRangeSamples below at a finer
  /// resolution; this stays hourly because "which hour had a gap or weak
  /// signal" is the actual question the timeline answers. A missing hour
  /// bucket (absent from the returned list) means literally nothing was
  /// recorded that hour.
  Future<List<HourlySample>> getHourlySamples(int hours) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(hours: hours))
        .millisecondsSinceEpoch;
    final result = await db.rawQuery(
      'SELECT (timestamp / 3600000) AS hour_bucket, AVG(bpm) AS mean_bpm, '
      'AVG(confidence) AS mean_confidence, COUNT(*) AS n '
      'FROM heart_rate WHERE timestamp >= ? '
      'GROUP BY hour_bucket ORDER BY hour_bucket ASC',
      [cutoff],
    );
    return result
        .map((r) => HourlySample(
              hourBucket: r['hour_bucket'] as int,
              meanBpm: (r['mean_bpm'] as num).toDouble(),
              meanConfidence: (r['mean_confidence'] as num?)?.toDouble(),
              count: r['n'] as int,
            ))
        .toList();
  }

  /// Mean/min/max BPM per [bucketMinutes]-wide bucket for the last [hours]
  /// hours — the Insights trend chart's data source. Finer than
  /// getHourlySamples (30 min vs 1 hour by default) so a session with only
  /// a handful of hours still has enough points to look like a real curve,
  /// and the min/max spread lets a brief spike or dip inside a bucket show
  /// up as the band widening instead of being averaged away to a flat
  /// line. A missing bucket means nothing was recorded in that window.
  Future<List<HrRangeSample>> getHrRangeSamples(int hours, {int bucketMinutes = 30}) async {
    final db = await database;
    final bucketMs = bucketMinutes * 60000;
    final cutoff = DateTime.now()
        .subtract(Duration(hours: hours))
        .millisecondsSinceEpoch;
    final result = await db.rawQuery(
      'SELECT (timestamp / ?) AS bucket, AVG(bpm) AS mean_bpm, '
      'MIN(bpm) AS min_bpm, MAX(bpm) AS max_bpm, COUNT(*) AS n '
      'FROM heart_rate WHERE timestamp >= ? '
      'GROUP BY bucket ORDER BY bucket ASC',
      [bucketMs, cutoff],
    );
    return result
        .map((r) => HrRangeSample(
              bucketStart: DateTime.fromMillisecondsSinceEpoch((r['bucket'] as int) * bucketMs),
              meanBpm: (r['mean_bpm'] as num).toDouble(),
              minBpm: (r['min_bpm'] as num).toDouble(),
              maxBpm: (r['max_bpm'] as num).toDouble(),
              count: r['n'] as int,
            ))
        .toList();
  }

  // Distinct hour buckets with at least one HR reading since [since] — same
  // "coverage" logic as getHourlyMeanHR but anchored to a fixed point in
  // time (e.g. midnight) instead of a rolling N-hour lookback, for showing
  // today's wear coverage on the Home dashboard.
  Future<int> getHoursWithDataSince(DateTime since) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(DISTINCT (timestamp / 3600000)) as cnt '
      'FROM heart_rate WHERE timestamp >= ?',
      [since.millisecondsSinceEpoch],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  // Average deviation from 1g (resting) across accelerometer samples in
  // [start, end) — a simple movement-intensity proxy. Returns null when
  // there's no accelerometer data in the window, so callers can distinguish
  // "no movement" from "nothing recorded yet". Fetches raw rows and sums in
  // Dart rather than in SQL since sqflite's bundled SQLite build isn't
  // guaranteed to have the math functions extension (SQRT) enabled.
  Future<double?> getAverageMovementIntensity({
    required DateTime start,
    required DateTime end,
  }) async {
    final db = await database;
    final rows = await db.query(
      'accelerometer',
      columns: ['x', 'y', 'z'],
      where: 'timestamp >= ? AND timestamp < ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
    );
    if (rows.isEmpty) return null;

    double sum = 0;
    for (final row in rows) {
      final x = (row['x'] as num).toDouble();
      final y = (row['y'] as num).toDouble();
      final z = (row['z'] as num).toDouble();
      final magnitudeG = math.sqrt(x * x + y * y + z * z) / 1000.0;
      sum += (magnitudeG - 1.0).abs();
    }
    return sum / rows.length;
  }

  Future<DateTime?> getLastReadingTime() async {
    final db = await database;
    final result = await db.rawQuery('SELECT MAX(timestamp) as last FROM heart_rate');
    final ts = result.first['last'] as int?;
    return ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
  }

  // Most recent HRM confidence value (0-100-ish), for showing real signal
  // quality instead of a made-up score.
  Future<int> getLatestConfidence() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT confidence FROM heart_rate WHERE confidence IS NOT NULL '
      'ORDER BY timestamp DESC LIMIT 1',
    );
    if (result.isEmpty) return 0;
    return (result.first['confidence'] as num?)?.toInt() ?? 0;
  }

  Future<int> getAvgConfidence({required int sinceMillis}) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT AVG(confidence) as avg FROM heart_rate '
      'WHERE confidence IS NOT NULL AND timestamp >= ?',
      [sinceMillis],
    );
    final avg = result.first['avg'] as num?;
    return avg?.round() ?? 0;
  }

  /// Finds stretches with no heart-rate reading for at least [threshold] —
  /// the same kind of gap that showed up as multi-minute/multi-hour blank
  /// stretches in exported session CSVs when background sync was silently
  /// failing. Surfaced in the Device screen so a gap is visible *during*
  /// the session instead of only discoverable afterward by eyeballing an
  /// exported file.
  ///
  /// Includes a trailing gap for "still ongoing right now" (most recent
  /// reading is itself older than [threshold]) with `end` set to the
  /// current time, distinct from a closed gap between two real readings.
  ///
  /// [since] bounds how far back to look — callers doing a live UI refresh
  /// should pass something like the last several hours rather than the
  /// full session, since this pulls every timestamp in range into memory
  /// to scan for consecutive deltas (fine for that scale; not something to
  /// run unbounded over a full 48h/~170k-row session on a timer).
  Future<List<ReadingGap>> findGaps({
    required Duration threshold,
    DateTime? since,
    int limit = 20,
  }) async {
    final db = await database;
    final rows = await db.query(
      'heart_rate',
      columns: ['timestamp'],
      where: since != null ? 'timestamp >= ?' : null,
      whereArgs: since != null ? [since.millisecondsSinceEpoch] : null,
      orderBy: 'timestamp ASC',
    );

    final gaps = <ReadingGap>[];

    for (var i = 1; i < rows.length; i++) {
      final prevMs = rows[i - 1]['timestamp'] as int;
      final currMs = rows[i]['timestamp'] as int;
      if (currMs - prevMs >= threshold.inMilliseconds) {
        gaps.add(ReadingGap(
          start: DateTime.fromMillisecondsSinceEpoch(prevMs),
          end: DateTime.fromMillisecondsSinceEpoch(currMs),
        ));
      }
    }

    if (rows.isNotEmpty) {
      final lastReading =
          DateTime.fromMillisecondsSinceEpoch(rows.last['timestamp'] as int);
      final sinceLast = DateTime.now().difference(lastReading);
      if (sinceLast >= threshold) {
        gaps.add(ReadingGap(start: lastReading, end: DateTime.now()));
      }
    }

    gaps.sort((a, b) => b.start.compareTo(a.start)); // most recent first
    return gaps.length > limit ? gaps.sublist(0, limit) : gaps;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }

  // ── DEBUG (preview builds only) ──────────────────────────────────────────
  // Bulk insert/clear used by lib/debug/debug_data_seeder.dart to populate a
  // realistic-looking session on the Android emulator, which has no real
  // watch to sync from. kDebugMode is const-folded to false in release
  // builds, so these are dead-code-eliminated and can never run on a
  // shipped build.

  Future<void> debugBulkInsert({
    required List<Map<String, dynamic>> heartRateRows,
    required List<Map<String, dynamic>> accelRows,
  }) async {
    if (!kDebugMode) return;
    final db = await database;
    final batch = db.batch();
    for (final row in heartRateRows) {
      batch.insert('heart_rate', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final row in accelRows) {
      batch.insert('accelerometer', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<void> debugClearAll() async {
    if (!kDebugMode) return;
    final db = await database;
    await db.delete('heart_rate');
    await db.delete('accelerometer');
    await db.delete('sessions');
  }
}

/// A stretch with no heart-rate reading for at least the caller's requested
/// threshold — see [DatabaseHelper.findGaps].
class ReadingGap {
  final DateTime start;
  final DateTime end;
  Duration get duration => end.difference(start);

  ReadingGap({required this.start, required this.end});
}

/// One hour's worth of HR data — see [DatabaseHelper.getHourlySamples].
/// [hourBucket] is `timestamp ~/ 3600000`, i.e. hours since the Unix
/// epoch, not an hour-of-day.
class HourlySample {
  final int hourBucket;
  final double meanBpm;
  final double? meanConfidence;
  final int count;

  HourlySample({
    required this.hourBucket,
    required this.meanBpm,
    required this.meanConfidence,
    required this.count,
  });
}

/// One bucket's worth of HR data at whatever resolution the caller asked
/// for — see [DatabaseHelper.getHrRangeSamples].
class HrRangeSample {
  final DateTime bucketStart;
  final double meanBpm;
  final double minBpm;
  final double maxBpm;
  final int count;

  HrRangeSample({
    required this.bucketStart,
    required this.meanBpm,
    required this.minBpm,
    required this.maxBpm,
    required this.count,
  });
}