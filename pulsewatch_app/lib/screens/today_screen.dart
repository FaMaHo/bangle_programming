import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';
import '../services/ble_service.dart';
import '../services/hrv_feature_extractor.dart';
import '../services/inference_service.dart';
import '../services/notification_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen>
    with SingleTickerProviderStateMixin {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final BleService _bleService = BleService();

  int _minHR = 0;
  int _maxHR = 0;
  int _avgHR = 0;
  int _totalReadings = 0;
  bool _isConnected = false;
  int _liveBpm = 0;
  double _riskScore = -1.0;
  DateTime? _lastEvalTime;
  int _liveRecordsReceived = 0;

  final List<BpmSample> _bpmBuffer = [];
  bool _evaluating = false;
  static const _windowDuration = Duration(minutes: 5);
  static const _minSamplesForRisk = 60;
  static const _evalCooldown = Duration(minutes: 2);

  late AnimationController _heartAnimController;
  late Animation<double> _heartScaleAnim;
  Timer? _heartBeatTimer;
  Timer? _statsTimer;

  StreamSubscription? _connectionSubscription;
  StreamSubscription? _transferSubscription;
  StreamSubscription? _liveSampleSubscription;

  @override
  void initState() {
    super.initState();

    _heartAnimController = AnimationController(
      duration: const Duration(milliseconds: 180),
      vsync: this,
    );
    _heartScaleAnim = Tween<double>(begin: 1.0, end: 1.35).animate(
      CurvedAnimation(parent: _heartAnimController, curve: Curves.easeOut),
    );
    _heartAnimController.addStatusListener((status) {
      if (status == AnimationStatus.completed) _heartAnimController.reverse();
    });

    NotificationService.initialize();
    _loadStats();
    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) => _loadStats());

    _connectionSubscription = _bleService.connectionStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isConnected = (state == BluetoothConnectionState.connected);
          if (!_isConnected) {
            _liveBpm = 0;
            _liveRecordsReceived = 0;
            _heartBeatTimer?.cancel();
            _bpmBuffer.clear();
          }
        });
      }
    });

    _transferSubscription = _bleService.transferProgressStream.listen((progress) {
      if (mounted) setState(() => _liveRecordsReceived = progress.recordsReceived);
    });

    _liveSampleSubscription = _bleService.liveSampleStream.listen((sample) {
      final bpm = sample.bpm.round();
      if (mounted) setState(() => _liveBpm = bpm);
      _resetHeartTimer(bpm);

      _bpmBuffer.add(sample);
      final cutoff = DateTime.now().subtract(_windowDuration);
      _bpmBuffer.removeWhere((s) => s.time.isBefore(cutoff));

      if (_bpmBuffer.length >= _minSamplesForRisk && !_evaluating) {
        final now = DateTime.now();
        if (_lastEvalTime == null || now.difference(_lastEvalTime!) >= _evalCooldown) {
          _evaluateRisk();
        }
      }
    });
  }

  Future<void> _evaluateRisk() async {
    if (_evaluating) return;
    _evaluating = true;
    _lastEvalTime = DateTime.now();
    try {
      final features = HrvFeatureExtractor.compute(List.from(_bpmBuffer));
      // Overlay nocturnal features from DB (replaces training-mean defaults).
      // PPG morphology features remain at training means — hardware calibration needed.
      final nocturnal = await HrvFeatureExtractor.computeNocturnal(_db);
      features['nocturnal_hr_mean']        = nocturnal['nocturnal_hr_mean']!;
      features['hrv_circadian_amplitude']  = nocturnal['hrv_circadian_amplitude']!;
      features['sleep_fragmentation_index'] = nocturnal['sleep_fragmentation_index']!;
      final score = await InferenceService.getRiskScore(features);
      print('[InferenceService] risk=${score.toStringAsFixed(3)}  buffer=${_bpmBuffer.length}');
      if (!mounted) return;
      setState(() => _riskScore = score);
      await NotificationService.sendRiskAlert(score);
      if (score > 0.75) await _bleService.sendRiskAlarm();
    } finally {
      _evaluating = false;
    }
  }

  void _resetHeartTimer(int bpm) {
    _heartBeatTimer?.cancel();
    if (bpm <= 0) return;
    final interval = Duration(milliseconds: (60000 / bpm).round());
    _heartBeatTimer = Timer.periodic(interval, (_) {
      if (mounted && !_heartAnimController.isAnimating) _heartAnimController.forward();
    });
  }

  Future<void> _loadStats() async {
    final stats = await _db.getTodayHRStats();
    final total = await _db.getTotalReadings();
    if (mounted) {
      setState(() {
        _minHR = (stats['minHR'] as num?)?.toInt() ?? 0;
        _maxHR = (stats['maxHR'] as num?)?.toInt() ?? 0;
        _avgHR = (stats['avgHR'] as num?)?.round() ?? 0;
        _totalReadings = total;
      });
    }
  }

  @override
  void dispose() {
    _heartAnimController.dispose();
    _heartBeatTimer?.cancel();
    _statsTimer?.cancel();
    _connectionSubscription?.cancel();
    _transferSubscription?.cancel();
    _liveSampleSubscription?.cancel();
    super.dispose();
  }

  Color _riskColor(double score) {
    if (score < 0.35) return AppColors.primaryGreen;
    if (score < 0.65) return AppColors.warning;
    return AppColors.error;
  }

  String _riskLabel(double score) {
    if (score < 0.35) return 'Low Risk';
    if (score < 0.65) return 'Moderate';
    return 'High Risk';
  }

  String _heartZone(int bpm) {
    if (bpm == 0) return '';
    if (bpm < 60) return 'Below Normal';
    if (bpm < 80) return 'Resting';
    if (bpm < 100) return 'Normal';
    if (bpm < 130) return 'Active';
    return 'Elevated';
  }

  Color _heartZoneColor(int bpm) {
    if (bpm == 0) return Colors.grey;
    if (bpm < 60) return Colors.blue;
    if (bpm < 100) return AppColors.primaryGreen;
    if (bpm < 130) return AppColors.warning;
    return AppColors.error;
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final bool hasLive = _isConnected && _liveBpm > 0;
    final bool hasRisk = _riskScore >= 0;
    final bool hasData = _totalReadings > 0 || _avgHR > 0;
    final int bufferCount = _bpmBuffer.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Today', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 4),
          Text(_getFormattedDate(), style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 24),

          // ── HERO RISK CARD ───────────────────────────────────────────────
          _buildRiskHeroCard(hasRisk, bufferCount),
          const SizedBox(height: 16),

          // ── LIVE HEARTBEAT CARD ──────────────────────────────────────────
          if (hasLive) ...[
            _buildLiveHRCard(),
            const SizedBox(height: 16),
          ],

          // ── HR SUMMARY ───────────────────────────────────────────────────
          if (hasData) _buildHRSummaryCard(),
        ],
      ),
    );
  }

  Widget _buildRiskHeroCard(bool hasRisk, int bufferCount) {
    // State 1: no watch connected, no prior score
    if (!_isConnected && !hasRisk) {
      return _buildConnectPromptCard();
    }

    // State 2: connected, still collecting enough data
    if (_isConnected && !hasRisk && bufferCount < _minSamplesForRisk) {
      return _buildCollectingCard(bufferCount);
    }

    // State 3: has a risk score — show the gauge
    return _buildRiskGaugeCard(hasRisk ? _riskScore : 0.0, bufferCount);
  }

  Widget _buildConnectPromptCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.primaryGreen.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.monitor_heart_outlined, color: AppColors.primaryGreen, size: 36),
          ),
          const SizedBox(height: 16),
          const Text(
            'No Risk Data Yet',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Connect your watch to start monitoring.\nA risk score appears after 60 readings.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildCollectingCard(int bufferCount) {
    final progress = bufferCount / _minSamplesForRisk;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.primaryGreen.withOpacity(0.25)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryGreen.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.monitor_heart, color: AppColors.primaryGreen, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cardiac Risk Assessment',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      'Collecting HRV data…',
                      style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: AppColors.primaryGreen.withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryGreen),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$bufferCount / $_minSamplesForRisk readings',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: TextStyle(
                  color: AppColors.primaryGreen,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRiskGaugeCard(double score, int bufferCount) {
    final color = _riskColor(score);
    final label = _riskLabel(score);
    final pct = (score * 100).round();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withOpacity(0.25), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Cardiac Risk Assessment',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Animated arc gauge
          TweenAnimationBuilder<double>(
            key: ValueKey(score),
            tween: Tween(begin: 0.0, end: score),
            duration: const Duration(milliseconds: 1000),
            curve: Curves.easeOutCubic,
            builder: (context, animated, _) {
              final animColor = _riskColor(animated);
              return SizedBox(
                width: 200,
                height: 130,
                child: CustomPaint(
                  painter: _RiskGaugePainter(
                    progress: animated,
                    trackColor: Colors.grey.shade200,
                    fillColor: animColor,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$pct%',
                          style: TextStyle(
                            color: color,
                            fontSize: 52,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          style: TextStyle(
                            color: color.withOpacity(0.8),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),

          // Footer
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.access_time, size: 12, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Text(
                _lastEvalTime != null
                    ? 'Updated ${_formatTime(_lastEvalTime!)}  ·  $bufferCount readings'
                    : '$bufferCount readings collected',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
              ),
            ],
          ),

          // Evaluation notice
          const SizedBox(height: 8),
          Text(
            'Based on 5-min HRV • re-evaluated every 2 min',
            style: TextStyle(color: AppColors.textSecondary.withOpacity(0.6), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveHRCard() {
    final bool hasLiveBpm = _liveBpm > 0;
    final Color heartColor =
        hasLiveBpm ? AppColors.secondaryCoral : AppColors.textSecondary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
      decoration: BoxDecoration(
        gradient: hasLiveBpm
            ? LinearGradient(
                colors: [
                  AppColors.secondaryCoral.withOpacity(0.10),
                  AppColors.secondaryCoral.withOpacity(0.03),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: hasLiveBpm ? null : AppColors.cardBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasLiveBpm
              ? AppColors.secondaryCoral.withOpacity(0.25)
              : AppColors.textSecondary.withOpacity(0.12),
        ),
      ),
      child: Row(
        children: [
          ScaleTransition(
            scale: _heartScaleAnim,
            child: Icon(
              hasLiveBpm ? Icons.favorite : Icons.favorite_border,
              color: heartColor,
              size: 40,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      hasLiveBpm ? '$_liveBpm' : '--',
                      style: TextStyle(
                        color: heartColor,
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        hasLiveBpm ? 'BPM  ·  Live' : 'BPM',
                        style: TextStyle(
                          color: heartColor.withOpacity(0.7),
                          fontSize: 13,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (hasLiveBpm)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: _heartZoneColor(_liveBpm).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _heartZone(_liveBpm),
                      style: TextStyle(
                        color: _heartZoneColor(_liveBpm),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  Text(
                    _isConnected ? 'Waiting for data...' : 'Watch not connected',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          if (hasLiveBpm) ...[  
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(Icons.radio_button_checked,
                    color: AppColors.primaryGreen, size: 12),
                const SizedBox(height: 2),
                Text(
                  '$_liveRecordsReceived',
                  style: TextStyle(
                    color: AppColors.primaryGreen,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Text(
                  'readings',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 10),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHRSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Heart Rate — Today',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatColumn('Min', _minHR, Icons.arrow_downward),
              _buildStatColumn('Avg', _avgHR, Icons.horizontal_rule),
              _buildStatColumn('Max', _maxHR, Icons.arrow_upward),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatColumn(String label, int value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: AppColors.textSecondary, size: 14),
        const SizedBox(height: 4),
        Text(
          value > 0 ? '$value' : '--',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
      ],
    );
  }

  String _getFormattedDate() {
    final now = DateTime.now();
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[now.month - 1]} ${now.day}, ${now.year}';
  }
}

class _RiskGaugePainter extends CustomPainter {
  final double progress;
  final Color trackColor;
  final Color fillColor;

  // 240° arc: starts at 150° (bottom-left), sweeps clockwise to 30° (bottom-right)
  static const double _startAngle = 5 * math.pi / 6; // 150°
  static const double _totalSweep = 4 * math.pi / 3; // 240°

  const _RiskGaugePainter({
    required this.progress,
    required this.trackColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.72);
    final radius = size.width * 0.42;
    const strokeWidth = 13.0;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      _startAngle,
      _totalSweep,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    final sweep = _totalSweep * progress.clamp(0.0, 1.0);
    if (sweep > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        _startAngle,
        sweep,
        false,
        Paint()
          ..color = fillColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RiskGaugePainter old) =>
      old.progress != progress || old.fillColor != fillColor;
}
