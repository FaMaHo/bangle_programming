// Seeds a local sqlite DB with synthetic data shaped exactly like what the
// real Bangle.js firmware (bangle/lib.js) sends and ble_service.dart parses
// and inserts, then runs the real ReportService/HrvFeatureExtractor/
// InferenceService pipeline end-to-end (including real ONNX inference)
// against it.
//
// Wire format ground truth (bangle/lib.js formatLine/onHRM):
//   timestamp,bpm,rr_interval_ms,confidence,accel_x,accel_y,accel_z
//   - fires ~once/sec while the HRM sensor is on
//   - accel_x/y/z are Math.round(accel.<axis> * 1000) — integer, "g" * 1000
//   - rr_interval_ms is an integer millisecond RR interval (0 if unknown)
// ble_service.dart (_subscribeToUARTBangle / _processFileData) parses that
// exact 7-field CSV line and calls:
//   db.insertHeartRateWithTimestamp(timestamp, bpm, rrIntervalMs, confidence, deviceId)
//   db.insertAccelerometerWithTimestamp(timestamp, x, y, z, deviceId)
// with both rows sharing the identical timestamp — which is what this test
// reproduces.

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pulsewatch_app/services/database_helper.dart';
import 'package:pulsewatch_app/services/inference_service.dart';
import 'package:pulsewatch_app/services/pdf_report_service.dart';
import 'package:pulsewatch_app/services/report_service.dart';

/// One synthetic sample, in exactly the fields the watch/ble_service produce.
class _WireSample {
  final int t; // ms epoch
  final int bpm;
  final int rr;
  final int confidence;
  final int x, y, z; // accel * 1000, ints

  _WireSample(this.t, this.bpm, this.rr, this.confidence, this.x, this.y, this.z);
}

/// Builds a physiologically-plausible 1Hz session: lower HR + near-zero
/// movement at night (00:00-06:00 local), daytime baseline HR with a few
/// activity bursts (elevated HR + high movement variance), matching the
/// real onHRM() cadence (~1 sample/sec) and field encoding.
List<_WireSample> _buildSyntheticSession({
  required DateTime start,
  required Duration duration,
  int seed = 42,
}) {
  final rnd = Random(seed);
  final samples = <_WireSample>[];
  final totalSeconds = duration.inSeconds;

  // A few activity bursts per day (e.g. a walk), each a few minutes long.
  final burstStarts = <int>[];
  for (int day = 0; day * 86400 < totalSeconds; day++) {
    burstStarts.add(day * 86400 + 8 * 3600 + rnd.nextInt(3600)); // morning
    burstStarts.add(day * 86400 + 17 * 3600 + rnd.nextInt(3600)); // evening
  }

  for (int s = 0; s < totalSeconds; s++) {
    final t = start.add(Duration(seconds: s));
    final hour = t.hour;
    final isNight = hour >= 0 && hour < 6;

    final inBurst = burstStarts.any((b) => s >= b && s < b + 240); // 4-min bursts

    double baseBpm;
    double accelNoise;
    if (isNight) {
      baseBpm = 55 + rnd.nextDouble() * 8; // 55-63 sleeping
      accelNoise = 5 + rnd.nextDouble() * 5; // near-static wrist
    } else if (inBurst) {
      baseBpm = 105 + rnd.nextDouble() * 20; // 105-125 active
      accelNoise = 300 + rnd.nextDouble() * 300; // large swings while walking
    } else {
      baseBpm = 68 + rnd.nextDouble() * 15; // 68-83 awake resting/light activity
      accelNoise = 20 + rnd.nextDouble() * 40; // small everyday movement
    }

    final bpm = baseBpm.round().clamp(40, 180);
    final rr = (60000 / bpm + (rnd.nextDouble() - 0.5) * 40).round().clamp(300, 2000);
    final confidence = 82 + rnd.nextInt(18); // 82-99, realistic good contact

    // Resting wrist orientation isn't flat — baseline splits gravity across
    // axes, then noise is layered on top exactly like real accelerometer
    // jitter/movement would.
    final x = (300 + (rnd.nextDouble() - 0.5) * accelNoise).round();
    final y = (200 + (rnd.nextDouble() - 0.5) * accelNoise).round();
    final z = (900 + (rnd.nextDouble() - 0.5) * accelNoise).round();

    samples.add(_WireSample(t.millisecondsSinceEpoch, bpm, rr, confidence, x, y, z));
  }

  return samples;
}

/// Bulk-seeds samples via the same db.insert(table, {...}) shape that
/// DatabaseHelper.insertHeartRateWithTimestamp/insertAccelerometerWithTimestamp
/// use — batched for speed since we're loading tens of thousands of rows,
/// but structurally identical to what ble_service.dart writes per sample.
Future<void> _bulkSeed(DatabaseHelper dbHelper, List<_WireSample> samples, {String deviceId = 'TEST-BANGLE'}) async {
  final db = await dbHelper.database;
  const chunkSize = 4000;
  for (int i = 0; i < samples.length; i += chunkSize) {
    final chunk = samples.skip(i).take(chunkSize);
    final batch = db.batch();
    for (final s in chunk) {
      batch.insert('heart_rate', {
        'timestamp': s.t,
        'bpm': s.bpm,
        'rr_interval_ms': s.rr,
        'confidence': s.confidence,
        'device_id': deviceId,
      });
      batch.insert('accelerometer', {
        'timestamp': s.t,
        'x': s.x,
        'y': s.y,
        'z': s.z,
        'device_id': deviceId,
      });
    }
    await batch.commit(noResult: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // sqflite_common_ffi persists to a real file on disk across process
    // runs (unlike the app's real per-device DB, this one survives between
    // `flutter test` invocations) — start every run from a clean slate.
    final dbPath = join(await getDatabasesPath(), 'pulsewatch.db');
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    // AuthService.scopedKey (used by ReportService's cache, now that the
    // cached report — and several other settings — are scoped per logged-in
    // user) reads the patient ID from secure storage, which has no real
    // platform implementation in a plain `flutter test` run. Fake it with
    // an in-memory map so the real AuthService/ReportService code under
    // test exercises actual per-user scoping instead of throwing
    // MissingPluginException. See flutter_secure_storage_platform_interface's
    // MethodChannelFlutterSecureStorage for the channel/method contract.
    final fakeSecureStorage = <String, String>{};
    const secureStorageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      switch (call.method) {
        case 'read':
          return fakeSecureStorage[args['key']];
        case 'write':
          fakeSecureStorage[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          fakeSecureStorage.remove(args['key']);
          return null;
        case 'deleteAll':
          fakeSecureStorage.clear();
          return null;
        case 'containsKey':
          return fakeSecureStorage.containsKey(args['key']);
        case 'readAll':
          return fakeSecureStorage;
        default:
          return null;
      }
    });
    // A patient ID must exist for AuthService.scopedKey to have something
    // to scope by — mirrors a real logged-in session.
    fakeSecureStorage['patient_id'] = 'TEST-PATIENT';

    await InferenceService.initialize();
  });

  // DatabaseHelper is a singleton over one shared on-device DB (same as in
  // the real app), so wipe between tests to avoid one test's seeded rows
  // leaking into another's "last 48h" window.
  tearDown(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('heart_rate');
    await db.delete('accelerometer');
  });

  test('ReportService.computeReport on an empty DB returns null', () async {
    final db = DatabaseHelper.instance;
    final report = await ReportService.computeReport(db);
    expect(report, isNull);
  });

  test('ReportService.computeReport below the 60-sample minimum window size returns null', () async {
    final db = DatabaseHelper.instance;
    final start = DateTime.now().subtract(const Duration(seconds: 30));
    final samples = _buildSyntheticSession(start: start, duration: const Duration(seconds: 30), seed: 1);

    // Go through the exact same DatabaseHelper methods ble_service.dart
    // calls per parsed wire line, one at a time (small enough to be fast),
    // to prove those methods work correctly with wire-shaped ints.
    for (final s in samples) {
      await db.insertHeartRateWithTimestamp(s.t, s.bpm, s.rr, s.confidence, 'TEST-BANGLE');
      await db.insertAccelerometerWithTimestamp(s.t, s.x, s.y, s.z, 'TEST-BANGLE');
    }

    final joined = await db.getHRWithAccelSince(start.millisecondsSinceEpoch);
    expect(joined.length, samples.length,
        reason: 'every HR row should join to its accel row via the shared timestamp, like real BLE data');
    expect(joined.first['bpm'], samples.first.bpm);
    expect(joined.first['x'], samples.first.x);

    final report = await ReportService.computeReport(db);
    expect(report, isNull, reason: 'below HrvFeatureExtractor.minSamples (60) — not enough for a single valid window');
  });

  test('ReportService.computeReport over a full realistic 48h+ session scores correctly', () async {
    final db = DatabaseHelper.instance;
    // Seed slightly more than 48h so the oldest couple of hours act as
    // margin against clock drift between seeding and scoring — computeReport
    // only looks at "the last 48h from now", so that margin is expected to
    // fall just outside the window by the time it queries, same as it would
    // for a real device that's been recording longer than the goal.
    const sessionSpan = Duration(hours: 50);
    final start = DateTime.now().subtract(sessionSpan);
    final samples = _buildSyntheticSession(start: start, duration: sessionSpan, seed: 7);
    expect(samples.length, 50 * 3600);

    final stopwatch = Stopwatch()..start();
    await _bulkSeed(db, samples);
    stopwatch.stop();
    // ignore: avoid_print
    print('Seeded ${samples.length} samples (${samples.length * 2} rows) in ${stopwatch.elapsedMilliseconds}ms');

    // Coverage check mirrors what home_screen.dart uses to decide the 48h
    // gate is satisfied (home_screen gates on `coverage.length >= 48`; a
    // continuous span not aligned to hour boundaries touches 49 distinct
    // hour-buckets, which still correctly satisfies ">=48").
    final coverage = await db.getHourlyMeanHR(48);
    expect(coverage.length, greaterThanOrEqualTo(48),
        reason: 'every one of the last 48 hours should have data (>=48 satisfies the home_screen gate)');

    final scoreStopwatch = Stopwatch()..start();
    final report = await ReportService.computeReport(db);
    scoreStopwatch.stop();
    // ignore: avoid_print
    print('computeReport took ${scoreStopwatch.elapsedMilliseconds}ms -> '
        'score=${report?.score} level=${report?.riskLevel} windows=${report?.nWindows}');

    expect(report, isNotNull);
    final r = report!;

    expect(r.score, inInclusiveRange(0.0, 1.0));
    expect(r.score.isNaN, isFalse);
    expect(['LOW', 'MEDIUM', 'HIGH'], contains(r.riskLevel));
    if (r.score < 0.20) {
      expect(r.riskLevel, 'LOW');
    } else if (r.score < 0.50) {
      expect(r.riskLevel, 'MEDIUM');
    } else {
      expect(r.riskLevel, 'HIGH');
    }

    // Only the most recent ~48h of the 50h seeded session falls inside
    // computeReport's "last 48h from now" cutoff — the oldest ~2h is
    // intentional margin (see comment above), so we expect roughly 48h/2.5min
    // windows, not the full 50h of seeded rows.
    expect(r.nWindows, greaterThan(1000));
    expect(r.nRows, lessThanOrEqualTo(samples.length));
    expect(r.nRows, greaterThan(48 * 3600 - 60));
    expect(r.durationHours, closeTo(48.0, 0.1));
    expect(r.meanHr, inInclusiveRange(40.0, 180.0));
    expect(r.meanRmssd, greaterThan(0));

    // All 22 model features should be present and finite (no NaN leaking
    // into the persisted/report JSON).
    final importances = await ReportService.loadImportances();
    expect(importances.length, 22);
    for (final key in importances.keys) {
      expect(r.aggFeatures.containsKey(key), isTrue, reason: 'missing feature: $key');
      expect(r.aggFeatures[key]!.isFinite, isTrue, reason: 'non-finite value for $key');
    }

    // Sanity-check the real feature_importance.json asset drives ranking:
    // sedentary_time_ratio / accel_entropy are the model's dominant features
    // (44% / 26%) and should show up near the top.
    final top = r.topFeatures(importances, count: 5).map((f) => f.key).toList();
    expect(top, contains('sedentary_time_ratio'));
    expect(top.first, 'sedentary_time_ratio');

    // Persistence round-trip (shared_preferences is mocked in setUpAll).
    final cached = await ReportService.loadCachedReport();
    expect(cached, isNotNull);
    expect(cached!.score, closeTo(r.score, 1e-9));
    expect(cached.nWindows, r.nWindows);
    expect(cached.aggFeatures.length, r.aggFeatures.length);

    // PDF export: a real multi-page document (see PdfReportService), not a
    // screenshot — verify it actually produces well-formed PDF bytes rather
    // than just trusting the widget tree doesn't throw.
    final pdfBytes = await PdfReportService.build(r, r.topFeatures(importances));
    expect(pdfBytes.length, greaterThan(1000), reason: 'suspiciously small for a real PDF');
    final header = String.fromCharCodes(pdfBytes.take(5));
    expect(header, '%PDF-', reason: 'must start with the PDF file signature');
    final tail = String.fromCharCodes(pdfBytes.skip(pdfBytes.length - 8));
    expect(tail.contains('%%EOF'), isTrue, reason: 'must end with a valid PDF EOF marker');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
