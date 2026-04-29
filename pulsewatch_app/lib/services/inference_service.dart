import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';

class InferenceService {
  static OrtSession? _session;
  static List<String> _featureNames = [];
  static bool _initialized = false;

  static bool get isInitialized => _initialized;

  static Future<void> initialize() async {
    if (_initialized) return;

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
  }

  /// Runs inference and returns P(cardiosclerosis) in [0.0, 1.0].
  /// Missing features default to 0.0.
  static Future<double> getRiskScore(Map<String, double> features) async {
    if (!_initialized) {
      throw StateError('InferenceService.initialize() must be called before getRiskScore()');
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

  static String getRiskLevel(double score) {
    if (score < 0.3) return 'Low';
    if (score < 0.6) return 'Medium';
    return 'High';
  }

  static void dispose() {
    _session?.release();
    OrtEnv.instance.release();
    _initialized = false;
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
// final level = InferenceService.getRiskLevel(score);
