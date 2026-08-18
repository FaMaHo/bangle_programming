import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;

import '../services/database_helper.dart';
import '../services/report_service.dart';

/// Generates a synthetic multi-hour watch session so Home/Insights/Report
/// screens can be previewed on the Android emulator, which has no real
/// watch to collect data from. Debug-build only — see kDebugMode.
class DebugDataSeeder {
  DebugDataSeeder._();

  static const _deviceId = 'SIMULATED-WATCH';
  static final _rand = Random();

  /// Inserts one HR+accel sample per second across [coverage], ending at
  /// [endAt] (defaults to now — pass an earlier time to simulate a session
  /// that went quiet a while ago, for previewing Insights' "last real
  /// reading" anchor instead of an ever-growing gap to the current
  /// moment). Set [includeGap] to leave a ~70min hole partway through —
  /// useful for previewing DeviceScreen's gap-detection card. Set
  /// [zeroBpmNoiseRate] (0-1) to occasionally log a garbage bpm=0 reading,
  /// the same sensor glitch Insights' "Lowest" stat now filters out. Set
  /// [injectCorruptTimestamp] to append one row with an implausible
  /// far-future timestamp (mirroring a real corrupted BLE-synced value seen
  /// in the field) — for verifying the RangeError guard added to
  /// DatabaseHelper/ServerService/BleService rejects/ignores it instead of
  /// crashing Home/Insights.
  static Future<void> seed({
    required Duration coverage,
    bool includeGap = false,
    DateTime? endAt,
    double zeroBpmNoiseRate = 0,
    bool injectCorruptTimestamp = false,
  }) async {
    if (!kDebugMode) return;

    // A stale cached report, session-start anchor, or paused flag from a
    // previous seed would otherwise keep showing on Home instead of
    // reflecting this newly-seeded coverage.
    await ReportService.debugResetSession();

    final db = DatabaseHelper.instance;
    final end = endAt ?? DateTime.now();
    final start = end.subtract(coverage);

    var hrRows = <Map<String, dynamic>>[];
    var accelRows = <Map<String, dynamic>>[];

    final gapStart = includeGap
        ? start.add(Duration(minutes: (coverage.inMinutes * 0.4).round()))
        : null;
    final gapEnd = gapStart?.add(const Duration(minutes: 70));

    for (var t = start; t.isBefore(end); t = t.add(const Duration(seconds: 1))) {
      if (gapStart != null && t.isAfter(gapStart) && t.isBefore(gapEnd!)) continue;

      final hourOfDay = t.hour + t.minute / 60.0;
      // Circadian dip around 4am, peak around 4pm.
      final circadian = -8 * cos((hourOfDay - 4) / 24 * 2 * pi);
      final isWaking = hourOfDay >= 7 && hourOfDay <= 22;
      final activity = isWaking ? _rand.nextDouble() : _rand.nextDouble() * 0.15;
      // A real sensor glitch reads as a flat zero regardless of the
      // "real" heart rate underneath — not a low value, an absent one —
      // so this branches before the normal hr calculation rather than
      // nudging it down.
      final isZeroNoise = zeroBpmNoiseRate > 0 && _rand.nextDouble() < zeroBpmNoiseRate;
      final hr = isZeroNoise
          ? 0
          : (68 + circadian + activity * 20 + (_rand.nextDouble() - 0.5) * 6)
              .clamp(48, 150)
              .round();
      final rr = (60000 / (hr == 0 ? 68 : hr) * (0.97 + _rand.nextDouble() * 0.06)).round();
      // Occasional poor-contact dip, otherwise a healthy HRM confidence —
      // deliberately not tied to isZeroNoise, since a real glitch reading
      // doesn't reliably come with a confidence drop (see this method's
      // doc comment).
      final confidence = (_rand.nextDouble() < 0.08)
          ? 30 + _rand.nextInt(30)
          : 80 + _rand.nextInt(19);

      final ts = t.millisecondsSinceEpoch;
      hrRows.add({
        'timestamp': ts,
        'bpm': hr,
        'rr_interval_ms': rr,
        'confidence': confidence,
        'device_id': _deviceId,
      });
      accelRows.add({
        'timestamp': ts,
        'x': (_rand.nextDouble() * activity * 400 - 200).round(),
        'y': (_rand.nextDouble() * activity * 400 - 200).round(),
        'z': (8192 + (_rand.nextDouble() * activity * 400 - 200)).round(),
        'device_id': _deviceId,
      });

      // Flush in chunks so a full 48h seed (172,800 samples) doesn't hold
      // everything in memory at once.
      if (hrRows.length >= 5000) {
        await db.debugBulkInsert(heartRateRows: hrRows, accelRows: accelRows);
        hrRows = [];
        accelRows = [];
      }
    }
    if (hrRows.isNotEmpty) {
      await db.debugBulkInsert(heartRateRows: hrRows, accelRows: accelRows);
    }

    if (injectCorruptTimestamp) {
      // The literal value observed in the field: a corrupted BLE-synced
      // reading landing ~566,000 years in the future, most likely from the
      // watch RTC not being set after a battery-dead reset. Inserted raw
      // (bypassing the normal per-second loop above) since it represents a
      // single bad row arriving amid otherwise-normal data, not a pattern.
      await db.debugBulkInsert(
        heartRateRows: [
          {
            'timestamp': 17861786878065918,
            'bpm': 72,
            'rr_interval_ms': 833,
            'confidence': 90,
            'device_id': _deviceId,
          },
        ],
        accelRows: const [],
      );
    }
  }

  static Future<void> clearAll() async {
    if (!kDebugMode) return;
    await DatabaseHelper.instance.debugClearAll();
    await ReportService.debugResetSession();
  }

  /// Undoes [seed] specifically — removes only the SIMULATED-WATCH rows it
  /// inserted, leaving a real watch's rows (and its cached report, once
  /// recomputed) untouched. Use this instead of [clearAll] whenever real
  /// data may already be in the database.
  static Future<void> clearSeeded() async {
    if (!kDebugMode) return;
    await DatabaseHelper.instance.debugClearDeviceId(_deviceId);
    await ReportService.debugClearCachedReport();
  }
}
