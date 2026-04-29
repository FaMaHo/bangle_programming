import 'dart:math' as math;
import 'database_helper.dart';

/// A single BLE sample bundled for HRV analysis.
/// Public so today_screen.dart and ble_service.dart can share this type.
class BpmSample {
  final DateTime time;
  final double bpm;
  final double ax, ay, az; // raw accelerometer counts from Bangle.js

  const BpmSample({
    required this.time,
    required this.bpm,
    required this.ax,
    required this.ay,
    required this.az,
  });
}

/// Computes 23 HRV + accel features from a rolling BPM window.
/// All features are derived from BPM and accelerometer data available over BLE.
/// PPG-morphology features (systolic_upslope, diastolic_decay, ai_index) and
/// long-term circadian features are not measurable from BPM alone — set to 0.0.
class HrvFeatureExtractor {
  static const int minSamples = 60; // ~1 min minimum for any meaningful HRV

  static Map<String, double> compute(List<BpmSample> window) {
    if (window.length < minSamples) return _zeros();

    // RR intervals (ms) approximated from BPM stream
    final rr = window.map((s) => 60000.0 / s.bpm).toList();
    final n = rr.length;
    final bpms = window.map((s) => s.bpm).toList();
    final mags = window
        .map((s) => math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az))
        .toList();

    // ── Time-domain HRV ──────────────────────────────────────────────────────
    final meanRr = _mean(rr);
    final sdnn = _std(rr);

    final diffs = <double>[];
    for (int i = 1; i < n; i++) {
      diffs.add((rr[i] - rr[i - 1]).abs());
    }
    final rmssd = diffs.isEmpty
        ? 0.0
        : math.sqrt(
            diffs.map((d) => d * d).reduce((a, b) => a + b) / diffs.length);
    final pnn50 =
        diffs.isEmpty ? 0.0 : diffs.where((d) => d > 50).length / diffs.length;
    final triIndex = _triIndex(rr);

    // ── Frequency-domain HRV (simple rectangular DFT — approximate) ─────────
    // RR series is treated as evenly sampled at 1 Hz (BPM stream rate).
    // Note: true RR intervals require beat-to-beat detection; this is an
    // approximation. LF/HF values are usable for relative risk comparison.
    final detrended = rr.map((v) => v - meanRr).toList();
    final bands = _spectralBands(detrended, 1.0);
    final lfPower = bands['lf']!;
    final hfPower = bands['hf']!;
    final lfHfRatio = hfPower > 1e-10 ? lfPower / hfPower : 0.0;
    final totalPower = bands['total']!;

    // ── Accelerometer features ───────────────────────────────────────────────
    final movVar = _std(mags);
    final meanMag = _mean(mags);
    // Sedentary: magnitude close to resting (within 10% of mean resting mag)
    final sedRatio = meanMag > 0
        ? mags.where((m) => (m - meanMag).abs() < meanMag * 0.10).length /
            mags.length
        : 0.0;
    final accelEntropy = _entropy(mags, 10);

    // ── HR dynamics ──────────────────────────────────────────────────────────
    final pulseAmp = rr.reduce(math.max) - rr.reduce(math.min);
    final hrStepRatio = _correlation(mags, bpms);
    final meanBpm = _mean(bpms);
    final chronoIndex = meanBpm > 0
        ? (bpms.reduce(math.max) - bpms.reduce(math.min)) / meanBpm
        : 0.0;

    final now = window.last.time;
    final slope1m = _slope(window
        .where((s) => now.difference(s.time) <= const Duration(seconds: 60))
        .map((s) => s.bpm)
        .toList());
    final slope3m = _slope(window
        .where((s) => now.difference(s.time) <= const Duration(seconds: 180))
        .map((s) => s.bpm)
        .toList());

    print(
        '[HrvFeatureExtractor] computed ${window.length} samples  rmssd=${rmssd.toStringAsFixed(1)}  lf/hf=${lfHfRatio.toStringAsFixed(2)}');

    return {
      'mean_rr': meanRr,
      'sdnn': sdnn,
      'rmssd': rmssd,
      'pnn50': pnn50,
      'tri_index': triIndex,
      'lf_power': lfPower,
      'hf_power': hfPower,
      'lf_hf_ratio': lfHfRatio,
      'total_power': totalPower,
      'pulse_amplitude': pulseAmp,
      // PPG waveform features unavailable from BPM stream.
      // Set to training-set mean so ONNX StandardScaler outputs 0 (neutral)
      // rather than an extreme outlier. Importances: upslope=6.1%, decay=8.2%.
      'systolic_upslope': 1262.26,
      'diastolic_decay': -1257.75,
      'ai_index': 2.39,            // 0% importance — value irrelevant
      'hr_step_ratio': hrStepRatio, // 0% importance — computed but ignored
      'chronotropic_index': chronoIndex, // 0% importance — computed but ignored
      'recovery_slope_1min': slope1m,
      'recovery_slope_3min': slope3m,
      'accel_entropy': accelEntropy,     // 0% importance — computed but ignored
      'movement_variability': movVar,    // 0% importance — computed but ignored
      'sedentary_time_ratio': sedRatio,  // 0% importance — computed but ignored
      // Long-term circadian features require overnight DB — set to training mean.
      // nocturnal_hr_mean=0.0 was -6.8 sigma after scaling (critical outlier).
      'nocturnal_hr_mean': 83.62,        // training mean, 2.1% importance
      'hrv_circadian_amplitude': 60.57,  // training mean, 1.2% importance
      'sleep_fragmentation_index': 0.051, // training mean, 2.3% importance
    };
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Computes nocturnal HR features from the SQLite database.
  /// Falls back to training-set means when insufficient data exists.
  /// Training means chosen so StandardScaler outputs 0 (neutral z-score).
  static Future<Map<String, double>> computeNocturnal(DatabaseHelper db) async {
    const kNoctMean   = 83.62;
    const kCircadian  = 60.57;
    const kFrag       = 0.051;

    final noctBpms = await db.getNocturnalHR();
    final double noctMean = noctBpms.isNotEmpty
        ? noctBpms.reduce((a, b) => a + b) / noctBpms.length
        : kNoctMean;

    final hourlyMeans = await db.getHourlyMeanHR(24);
    final double circadian = hourlyMeans.length >= 6
        ? hourlyMeans.reduce(math.max) - hourlyMeans.reduce(math.min)
        : kCircadian;

    double fragmentation = kFrag;
    if (noctBpms.length >= 5) {
      int jumps = 0;
      for (int i = 1; i < noctBpms.length; i++) {
        if ((noctBpms[i] - noctBpms[i - 1]).abs() > 10) jumps++;
      }
      fragmentation = jumps / (noctBpms.length - 1);
    }

    print('[HrvFeatureExtractor] nocturnal: mean=${noctMean.toStringAsFixed(1)} '
        'circ=${circadian.toStringAsFixed(1)} '
        'frag=${fragmentation.toStringAsFixed(3)} '
        '(n=${noctBpms.length} sleep samples)');

    return {
      'nocturnal_hr_mean': noctMean,
      'hrv_circadian_amplitude': circadian,
      'sleep_fragmentation_index': fragmentation,
    };
  }

  static double _mean(List<double> v) {
    if (v.isEmpty) return 0.0;
    return v.reduce((a, b) => a + b) / v.length;
  }

  static double _std(List<double> v) {
    if (v.length < 2) return 0.0;
    final m = _mean(v);
    final variance =
        v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / (v.length - 1);
    return math.sqrt(variance);
  }

  static double _triIndex(List<double> rr) {
    if (rr.length < 10) return 0.0;
    const binSize = 8.0; // 8 ms bins (standard)
    final minV = rr.reduce(math.min);
    final maxV = rr.reduce(math.max);
    final numBins = ((maxV - minV) / binSize).ceil() + 1;
    if (numBins <= 0) return 0.0;
    final hist = List<int>.filled(numBins, 0);
    for (final v in rr) {
      final bin = ((v - minV) / binSize).floor().clamp(0, numBins - 1);
      hist[bin]++;
    }
    final peak = hist.reduce(math.max);
    return peak > 0 ? rr.length / peak.toDouble() : 0.0;
  }

  /// Computes LF, HF, and total band powers in one DFT pass.
  /// Uses a simple rectangular DFT (no windowing) — approximate but consistent.
  /// signal must be detrended (DC removed). sampleRate in Hz.
  static Map<String, double> _spectralBands(
      List<double> signal, double sampleRate) {
    final n = signal.length;
    if (n < 4) return {'lf': 0.0, 'hf': 0.0, 'total': 0.0};

    double lf = 0.0, hf = 0.0, total = 0.0;

    for (int k = 1; k < n ~/ 2; k++) {
      final freq = k * sampleRate / n;
      double re = 0.0, im = 0.0;
      for (int j = 0; j < n; j++) {
        final angle = 2.0 * math.pi * k * j / n;
        re += signal[j] * math.cos(angle);
        im -= signal[j] * math.sin(angle);
      }
      final power = (re * re + im * im) / (n.toDouble() * n.toDouble());

      if (freq >= 0.003 && freq <= 0.40) total += power;
      if (freq >= 0.04 && freq <= 0.15) lf += power;
      if (freq >= 0.15 && freq <= 0.40) hf += power;
    }

    return {'lf': lf, 'hf': hf, 'total': total};
  }

  static double _entropy(List<double> vals, int numBins) {
    if (vals.length < 2) return 0.0;
    final minV = vals.reduce(math.min);
    final maxV = vals.reduce(math.max);
    if (maxV - minV < 1e-10) return 0.0;
    final hist = List<int>.filled(numBins, 0);
    for (final v in vals) {
      final bin = ((v - minV) / (maxV - minV) * (numBins - 1))
          .floor()
          .clamp(0, numBins - 1);
      hist[bin]++;
    }
    double entropy = 0.0;
    for (final count in hist) {
      if (count > 0) {
        final p = count / vals.length;
        entropy -= p * math.log(p) / math.log(2);
      }
    }
    return entropy;
  }

  static double _correlation(List<double> x, List<double> y) {
    if (x.length != y.length || x.length < 2) return 0.0;
    final mx = _mean(x), my = _mean(y);
    double num = 0.0, dx2 = 0.0, dy2 = 0.0;
    for (int i = 0; i < x.length; i++) {
      final xi = x[i] - mx, yi = y[i] - my;
      num += xi * yi;
      dx2 += xi * xi;
      dy2 += yi * yi;
    }
    final denom = math.sqrt(dx2 * dy2);
    return denom > 1e-10 ? num / denom : 0.0;
  }

  static double _slope(List<double> vals) {
    if (vals.length < 2) return 0.0;
    final meanX = (vals.length - 1) / 2.0;
    final meanY = _mean(vals);
    double num = 0.0, denom = 0.0;
    for (int i = 0; i < vals.length; i++) {
      num += (i - meanX) * (vals[i] - meanY);
      denom += (i - meanX) * (i - meanX);
    }
    return denom > 1e-10 ? num / denom : 0.0;
  }

  static Map<String, double> _zeros() => {
        'mean_rr': 0.0, 'sdnn': 0.0, 'rmssd': 0.0, 'pnn50': 0.0,
        'tri_index': 0.0, 'lf_power': 0.0, 'hf_power': 0.0,
        'lf_hf_ratio': 0.0, 'total_power': 0.0, 'pulse_amplitude': 0.0,
        'systolic_upslope': 0.0, 'diastolic_decay': 0.0, 'ai_index': 0.0,
        'hr_step_ratio': 0.0, 'chronotropic_index': 0.0,
        'recovery_slope_1min': 0.0, 'recovery_slope_3min': 0.0,
        'accel_entropy': 0.0, 'movement_variability': 0.0,
        'sedentary_time_ratio': 0.0, 'nocturnal_hr_mean': 0.0,
        'hrv_circadian_amplitude': 0.0, 'sleep_fragmentation_index': 0.0,
      };
}
