import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

class InferenceService {
  static OrtSession? _session;
  static List<String> _featureNames = [];
  static bool _initialized = false;

  // Debug-build-only stand-in for when the real ONNX native library can't
  // load for this ABI — e.g. the x86_64 Android emulator used to preview
  // screens without the physical watch (the onnxruntime plugin only ships
  // arm64-v8a/armeabi-v7a .so files; see its android/src/main/jniLibs).
  // Gated on kDebugMode so a genuine production failure to load the model
  // still surfaces as a real failure instead of silently faking a score.
  static bool _usingDebugFallback = false;

  static bool get isInitialized => _initialized;

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      OrtEnv.instance.init();

      final modelData = await rootBundle.load('assets/models/model.onnx');
      final modelBytes = modelData.buffer.asUint8List();

      final sessionOptions = OrtSessionOptions();
      _session = OrtSession.fromBuffer(modelBytes, sessionOptions);

      final jsonStr = await rootBundle.loadString('assets/models/feature_names.json');
      _featureNames = List<String>.from(jsonDecode(jsonStr) as List);

      _initialized = true;

      final inputName = _session!.inputNames.first;
      final outputNames = _session!.outputNames;
      print('[InferenceService] initialized');
      print('[InferenceService] input: $inputName  shape: [1, ${_featureNames.length}]');
      print('[InferenceService] outputs: $outputNames');
    } catch (e) {
      if (!kDebugMode) rethrow;
      print('[InferenceService] ONNX runtime unavailable ($e) — using a '
          'synthetic scorer for preview purposes.');
      final jsonStr = await rootBundle.loadString('assets/models/feature_names.json');
      _featureNames = List<String>.from(jsonDecode(jsonStr) as List);
      _usingDebugFallback = true;
      _initialized = true;
    }
  }

  /// Runs inference and returns P(cardiosclerosis) in [0.0, 1.0].
  /// Missing features default to 0.0.
  static Future<double> getRiskScore(Map<String, double> features) async {
    if (!_initialized) {
      throw StateError('InferenceService.initialize() must be called before getRiskScore()');
    }

    if (_usingDebugFallback) {
      return _syntheticRiskScore(features);
    }

    final inputData = Float32List(_featureNames.length);
    for (int i = 0; i < _featureNames.length; i++) {
      inputData[i] = (features[_featureNames[i]] ?? 0.0);
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      inputData,
      [1, _featureNames.length],
    );

    final runOptions = OrtRunOptions();
    final outputs = _session!.run(runOptions, {'float_input': inputTensor});

    // output[1] is 'probabilities' shaped [1, 2]; index [0][1] = P(cardiosclerosis)
    final probabilities = outputs![1]!.value as List<List<double>>;
    final risk = probabilities[0][1];

    inputTensor.release();
    runOptions.release();
    for (final out in outputs) {
      out?.release();
    }

    return risk;
  }

  /// Deliberately-not-clinical stand-in for the trained model — enough
  /// spread across LOW/MEDIUM/HIGH to preview the report screen's states
  /// when the real ONNX runtime can't load. See _usingDebugFallback.
  static double _syntheticRiskScore(Map<String, double> features) {
    final sedentary = features['sedentary_time_ratio'] ?? 0.5;
    final entropy = ((features['accel_entropy'] ?? 2.0) / 4.0).clamp(0.0, 1.0);
    final rmssd = ((features['rmssd'] ?? 30.0) / 100.0).clamp(0.0, 1.0);
    final raw = sedentary * 0.5 + (1 - entropy) * 0.3 + (1 - rmssd) * 0.2;
    return raw.clamp(0.02, 0.97);
  }

  static void dispose() {
    if (!_usingDebugFallback) {
      _session?.release();
      OrtEnv.instance.release();
    }
    _initialized = false;
    _usingDebugFallback = false;
  }
}

// Usage example:
// final features = {
//   'mean_rr': 750.0,
//   'sdnn': 45.0,
//   'rmssd': 35.0,
//   ... (any subset — missing features default to 0.0)
// };
// final score = await InferenceService.getRiskScore(features);
