import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'database_helper.dart';
import 'hrv_feature_extractor.dart';
import 'inference_service.dart';
import 'notification_service.dart';

/// Clinical label, unit, and plain-English meaning for each of the 22 model
/// features — ported verbatim from fromDaria/generate_report_html.py's
/// FEAT_INFO table (minus diastolic_decay, which isn't one of the trained
/// model's features).
const Map<String, List<String>> kFeatureInfo = {
  'lf_power':                  ['LF Power', 'ms²', 'Low-frequency HRV band — reflects sympathetic nervous system activity. Elevated in cardiac fibrosis.'],
  'tri_index':                 ['Triangular Index', '', 'How peaked the RR histogram is. Low = rigid, fibrotic heartbeat pattern.'],
  'pulse_amplitude':           ['Pulse Amplitude', 'ADC', 'Strength of the PPG pulse wave. Reduced in arterial stiffness.'],
  'systolic_upslope':          ['Systolic Upslope', '', 'Speed of pressure rise during heartbeat. Slows with myocardial stiffening.'],
  'pnn50':                     ['pNN50', '%', 'Fraction of consecutive beats differing by >50ms. Low = reduced parasympathetic tone.'],
  'mean_rr':                   ['Mean RR', 'ms', 'Average time between heartbeats. Shorter = higher resting heart rate.'],
  'rmssd':                     ['RMSSD', 'ms', 'Root mean square of successive RR differences. The most direct HRV marker.'],
  'sleep_fragmentation_index': ['Sleep Fragmentation', '', 'How often HR changes sharply during sleep. Elevated in cardiac autonomic dysfunction.'],
  'lf_hf_ratio':                ['LF/HF Ratio', '', 'Sympathetic vs parasympathetic balance. High ratio = sympathetic dominance.'],
  'hf_power':                  ['HF Power', 'ms²', 'High-frequency HRV band — reflects parasympathetic (vagal) activity.'],
  'nocturnal_hr_mean':         ['Nocturnal HR Mean', 'bpm', 'Average heart rate during sleep. Elevated in early cardiac fibrosis.'],
  'sdnn':                      ['SDNN', 'ms', 'Standard deviation of all RR intervals. Overall HRV measure.'],
  'recovery_slope_1min':       ['Recovery Slope 1min', 'bpm/s', 'How fast HR drops in first minute after activity peak.'],
  'total_power':               ['Total HRV Power', 'ms²', 'Total variance in RR intervals across all frequency bands.'],
  'ai_index':                  ['Augmentation Index', '', 'Ratio of augmented pressure to pulse pressure. Arterial stiffness marker.'],
  'sedentary_time_ratio':      ['Sedentary Time', '%', 'Fraction of time with minimal wrist movement.'],
  'accel_entropy':             ['Accel. Entropy', '', 'Randomness of movement patterns. Low = very sedentary lifestyle.'],
  'hr_step_ratio':             ['HR/Step Ratio', '', 'Heart rate relative to movement. Elevated = inefficient cardiac response.'],
  'chronotropic_index':        ['Chronotropic Index', '', 'Correlation of HR with activity. Low = reduced ability to raise HR on demand.'],
  'hrv_circadian_amplitude':   ['Circadian HRV Amplitude', 'ms', 'Day-night difference in HRV. Blunted in autonomic dysfunction.'],
  'movement_variability':      ['Movement Variability', '', 'Variation in accelerometer signal across the session.'],
  'recovery_slope_3min':       ['Recovery Slope 3min', 'bpm/s', 'Heart rate drop over 3 minutes after peak activity.'],
};

class FeatureRow {
  final String key;
  final String label;
  final String unit;
  final String description;
  final double value;
  final double importance;

  FeatureRow({
    required this.key,
    required this.label,
    required this.unit,
    required this.description,
    required this.value,
    required this.importance,
  });
}

class FinalReport {
  final double score;
  final String riskLevel; // LOW / MEDIUM / HIGH
  final String assessment;
  final Map<String, double> aggFeatures;
  final int nWindows;
  final int nRows;
  final double durationHours;
  final double meanHr;
  final double meanRmssd;
  final DateTime computedAt;

  FinalReport({
    required this.score,
    required this.riskLevel,
    required this.assessment,
    required this.aggFeatures,
    required this.nWindows,
    required this.nRows,
    required this.durationHours,
    required this.meanHr,
    required this.meanRmssd,
    required this.computedAt,
  });

  Map<String, dynamic> toJson() => {
        'score': score,
        'riskLevel': riskLevel,
        'assessment': assessment,
        'aggFeatures': aggFeatures,
        'nWindows': nWindows,
        'nRows': nRows,
        'durationHours': durationHours,
        'meanHr': meanHr,
        'meanRmssd': meanRmssd,
        'computedAt': computedAt.millisecondsSinceEpoch,
      };

  factory FinalReport.fromJson(Map<String, dynamic> j) => FinalReport(
        score: (j['score'] as num).toDouble(),
        riskLevel: j['riskLevel'] as String,
        assessment: j['assessment'] as String,
        aggFeatures: (j['aggFeatures'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, (v as num).toDouble())),
        nWindows: j['nWindows'] as int,
        nRows: j['nRows'] as int,
        durationHours: (j['durationHours'] as num).toDouble(),
        meanHr: (j['meanHr'] as num).toDouble(),
        meanRmssd: (j['meanRmssd'] as num).toDouble(),
        computedAt: DateTime.fromMillisecondsSinceEpoch(j['computedAt'] as int),
      );

  /// Top features by trained-model importance, joined with clinical info,
  /// for the report's feature table.
  List<FeatureRow> topFeatures(Map<String, double> importances, {int count = 8}) {
    final entries = importances.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(count).map((e) {
      final info = kFeatureInfo[e.key] ?? [e.key, '', ''];
      return FeatureRow(
        key: e.key,
        label: info[0],
        unit: info[1],
        description: info[2],
        value: aggFeatures[e.key] ?? 0.0,
        importance: e.value,
      );
    }).toList();
  }
}

/// Computes and persists the one-time, full-session cardiac risk report.
///
/// Mirrors fromDaria/generate_report_html.py: slides a 5-minute window
/// (50% overlap) across the *entire* collected session, scores each window,
/// and averages the per-window probabilities into a single session score —
/// rather than scoring one short live window, which is what the model was
/// actually trained/evaluated to do.
class ReportService {
  ReportService._();

  static const _prefsKey = 'final_report_v1';
  static const _windowDuration = Duration(minutes: 5);
  static const _windowStep = Duration(minutes: 2, seconds: 30);
  static const collectionGoal = Duration(hours: 48);

  static Map<String, double>? _importances;

  static Future<Map<String, double>> _loadImportances() async {
    if (_importances != null) return _importances!;
    final jsonStr = await rootBundle.loadString('assets/models/feature_importance.json');
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
    final imp = (decoded['feature_importances'] as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, (v as num).toDouble()));
    _importances = imp;
    return imp;
  }

  static Future<Map<String, double>> loadImportances() => _loadImportances();

  /// Scoped per-user (see AuthService.scopedKey) — this is a cardiac risk
  /// report, about as sensitive as this app's data gets, so it must never
  /// be readable by whichever account happens to log in next on this
  /// device.
  static Future<FinalReport?> loadCachedReport() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await AuthService.instance.scopedKey(_prefsKey));
    if (raw == null) return null;
    try {
      return FinalReport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveReport(FinalReport report) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await AuthService.instance.scopedKey(_prefsKey), jsonEncode(report.toJson()));
  }

  /// Debug-only: clears the cached report so re-seeding a fresh 48h session
  /// (see lib/debug/debug_data_seeder.dart) recomputes from scratch instead
  /// of showing a stale report from a previous seed. No-op in release
  /// builds — see kDebugMode.
  static Future<void> debugClearCachedReport() async {
    if (!kDebugMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(await AuthService.instance.scopedKey(_prefsKey));
  }

  /// Computes the final report from every sample in the last 48h of the
  /// local DB. Returns null (and persists nothing) if there isn't enough
  /// data to form a single valid window, so the caller can retry later.
  static Future<FinalReport?> computeReport(DatabaseHelper db) async {
    final cutoff = DateTime.now().subtract(collectionGoal).millisecondsSinceEpoch;
    final rows = await db.getHRWithAccelSince(cutoff);
    if (rows.isEmpty) return null;

    final samples = rows
        .map((r) => BpmSample(
              time: DateTime.fromMillisecondsSinceEpoch(r['timestamp'] as int),
              bpm: (r['bpm'] as num).toDouble(),
              ax: (r['x'] as num).toDouble(),
              ay: (r['y'] as num).toDouble(),
              az: (r['z'] as num).toDouble(),
              rr: (r['rr'] as num).toDouble(),
            ))
        .toList();

    // Session-level circadian/nocturnal features, applied to every window —
    // these describe the whole recording, not a single 5-min slice.
    final nocturnal = await HrvFeatureExtractor.computeNocturnal(db);

    final windowFeats = <Map<String, double>>[];
    final windowProbs = <double>[];

    // Two-pointer sliding window over timestamp-sorted samples.
    int lo = 0;
    DateTime windowStart = samples.first.time;
    final sessionEnd = samples.last.time;
    while (windowStart.isBefore(sessionEnd)) {
      final windowEnd = windowStart.add(_windowDuration);
      while (lo < samples.length && samples[lo].time.isBefore(windowStart)) {
        lo++;
      }
      int hi = lo;
      final window = <BpmSample>[];
      while (hi < samples.length && samples[hi].time.isBefore(windowEnd)) {
        window.add(samples[hi]);
        hi++;
      }

      if (window.length >= HrvFeatureExtractor.minSamples) {
        final feats = HrvFeatureExtractor.compute(window);
        feats['nocturnal_hr_mean'] = nocturnal['nocturnal_hr_mean']!;
        feats['hrv_circadian_amplitude'] = nocturnal['hrv_circadian_amplitude']!;
        feats['sleep_fragmentation_index'] = nocturnal['sleep_fragmentation_index']!;

        final prob = await InferenceService.getRiskScore(feats);
        windowFeats.add(feats);
        windowProbs.add(prob);
      }

      windowStart = windowStart.add(_windowStep);
    }

    if (windowProbs.isEmpty) return null;

    final sessionScore = windowProbs.reduce((a, b) => a + b) / windowProbs.length;

    final aggFeatures = <String, double>{};
    for (final key in windowFeats.first.keys) {
      final vals = windowFeats.map((f) => f[key]!).toList();
      aggFeatures[key] = vals.reduce((a, b) => a + b) / vals.length;
    }

    final hrVals = samples.map((s) => s.bpm).where((v) => v > 0).toList();
    final meanHr = hrVals.isEmpty ? 0.0 : hrVals.reduce((a, b) => a + b) / hrVals.length;
    final durationHours =
        samples.last.time.difference(samples.first.time).inSeconds / 3600.0;

    String riskLevel;
    String assessment;
    if (sessionScore < 0.20) {
      riskLevel = 'LOW';
      assessment = 'No significant cardiosclerosis markers detected. Readings are '
          'consistent with a healthy cardiovascular profile. Maintain regular '
          'activity and monitoring.';
    } else if (sessionScore < 0.50) {
      riskLevel = 'MEDIUM';
      assessment = 'Some autonomic markers associated with early cardiac stress '
          'detected. This score warrants clinical follow-up. Please consult a '
          'cardiologist for further evaluation.';
    } else {
      riskLevel = 'HIGH';
      assessment = 'Multiple markers consistent with significant cardiac autonomic '
          'dysfunction detected. Prompt clinical evaluation is strongly recommended.';
    }

    final report = FinalReport(
      score: sessionScore,
      riskLevel: riskLevel,
      assessment: assessment,
      aggFeatures: aggFeatures,
      nWindows: windowProbs.length,
      nRows: samples.length,
      durationHours: durationHours,
      meanHr: meanHr,
      meanRmssd: aggFeatures['rmssd'] ?? 0.0,
      computedAt: DateTime.now(),
    );

    await _saveReport(report);

    // The report is already safely cached above — a notification failure
    // (platform quirk, permission denial, plugin not ready) must never
    // take the whole computation down with it. This only runs once per
    // session; losing the freshly-scored report to an unrelated
    // notification hiccup would be a much worse outcome than just missing
    // the notification.
    try {
      // Always fires — sendRiskAlert below only does for higher scores, so
      // without this a low/medium-risk session (the common case) would
      // finish with no notification at all telling the user to go look.
      await NotificationService.sendReportReadyAlert();
      await NotificationService.sendRiskAlert(sessionScore);
    } catch (_) {}

    return report;
  }
}
