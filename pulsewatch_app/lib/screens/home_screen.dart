import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';
import '../services/ble_service.dart';
import '../services/notification_service.dart';
import '../services/report_service.dart';
import '../services/server_service.dart';
import 'report_screen.dart';
import 'settings_screen.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Home dashboard — the first thing a user sees. Answers, at a glance:
/// is the watch connected, how much data have we collected toward the
/// 48h goal, and is there anything the user needs to go do (connect the
/// watch, upload data).
///
/// The cardiac risk score is only ever computed once, from the full 48h
/// session (see ReportService) — never from a short live window, which
/// isn't how the model was trained/evaluated and produced unreliable
/// high-risk false positives.
class HomeScreen extends StatefulWidget {
  final void Function(int tabIndex) onNavigateToTab;

  const HomeScreen({super.key, required this.onNavigateToTab});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final BleService _bleService = BleService();
  final ServerService _server = ServerService.instance;

  int _minHR = 0;
  int _maxHR = 0;
  int _avgHR = 0;
  int _totalReadings = 0;
  bool _isConnected = false;
  int _coverageHours = 0; // distinct hours with data in the last 48h
  bool _needsUpload = false;

  static const _collectionGoalHours = 48;

  FinalReport? _report;
  bool _generatingReport = false;

  Timer? _statsTimer;

  StreamSubscription? _connectionSubscription;

  @override
  void initState() {
    super.initState();

    NotificationService.initialize();
    _isConnected = _bleService.isConnected;
    _loadStats();
    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) => _loadStats());

    _connectionSubscription = _bleService.connectionStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isConnected = (state == BluetoothConnectionState.connected);
        });
      }
      if (state == BluetoothConnectionState.connected) {
        _maybeShowBatteryExemptionPrompt();
      }
    });
  }

  /// Offered once, the first time we see a successful connection where the
  /// app isn't already exempted — battery optimization is what silently
  /// throttled/killed the background connection during earlier testing.
  Future<void> _maybeShowBatteryExemptionPrompt() async {
    if (!await _bleService.needsBatteryExemptionPrompt()) return;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep recording reliable'),
        content: const Text(
          'Your phone\'s battery settings can pause PulseWatch in the '
          'background, which can interrupt your 48-hour session. On the '
          'next screen, choose "Allow" (or "Unrestricted") so recording '
          'keeps running the whole time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _bleService.requestBatteryExemption();
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    await _bleService.markBatteryExemptionAsked();
  }

  /// Kicks off the one-time full-session report once 48h of data has been
  /// collected. No-op if a report already exists or is already generating.
  Future<void> _maybeGenerateReport() async {
    if (_report != null || _generatingReport) return;
    if (_coverageHours < _collectionGoalHours) return;

    setState(() => _generatingReport = true);
    final report = await ReportService.computeReport(_db);
    if (!mounted) return;
    setState(() {
      _generatingReport = false;
      if (report != null) _report = report;
    });
  }

  Future<void> _loadStats() async {
    final stats = await _db.getTodayHRStats();
    final total = await _db.getTotalReadings();
    final coverage = await _db.getHourlyMeanHR(_collectionGoalHours);
    final lastReading = await _db.getLastReadingTime();
    final lastUpload = await _server.getLastUploadTime();

    final needsUpload = lastReading != null &&
        (lastUpload == null || lastReading.isAfter(lastUpload));

    if (mounted) {
      setState(() {
        _minHR = (stats['minHR'] as num?)?.toInt() ?? 0;
        _maxHR = (stats['maxHR'] as num?)?.toInt() ?? 0;
        _avgHR = (stats['avgHR'] as num?)?.round() ?? 0;
        _totalReadings = total;
        _coverageHours = coverage.length;
        _needsUpload = needsUpload;
      });
    }

    if (_report == null && !_generatingReport) {
      final cached = await ReportService.loadCachedReport();
      if (cached != null) {
        if (mounted) setState(() => _report = cached);
      } else {
        await _maybeGenerateReport();
      }
    }
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }

  Color _riskColor(String level) {
    switch (level) {
      case 'LOW':
        return AppColors.primaryGreen;
      case 'MEDIUM':
        return AppColors.warning;
      default:
        return AppColors.error;
    }
  }

  String _riskLabel(String level) {
    switch (level) {
      case 'LOW':
        return 'Low Risk';
      case 'MEDIUM':
        return 'Moderate';
      default:
        return 'High Risk';
    }
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final bool hasData = _totalReadings > 0 || _avgHR > 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Home', style: Theme.of(context).textTheme.headlineLarge),
              IconButton(
                icon: const Icon(Icons.settings_outlined, color: AppColors.textSecondary),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
          Text(_getFormattedDate(), style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 24),

          // ── WATCH STATUS ─────────────────────────────────────────────────
          _buildWatchStatusCard(),
          const SizedBox(height: 16),

          // ── UPLOAD NUDGE ─────────────────────────────────────────────────
          if (_needsUpload) ...[
            _buildUploadNudgeCard(),
            const SizedBox(height: 16),
          ],

          // ── HERO RISK CARD ───────────────────────────────────────────────
          _buildRiskHeroCard(),
          const SizedBox(height: 16),

          // ── 48H COLLECTION PROGRESS ──────────────────────────────────────
          _buildCollectionProgressCard(),
          const SizedBox(height: 16),

          // ── HR SUMMARY ───────────────────────────────────────────────────
          if (hasData) _buildHRSummaryCard(),
        ],
      ),
    );
  }

  Widget _buildWatchStatusCard() {
    return GestureDetector(
      onTap: _isConnected ? null : () => widget.onNavigateToTab(2),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: _isConnected
              ? AppColors.primaryGreen.withOpacity(0.08)
              : AppColors.cardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isConnected
                ? AppColors.primaryGreen.withOpacity(0.25)
                : AppColors.warning.withOpacity(0.4),
          ),
        ),
        child: Row(
          children: [
            Icon(
              _isConnected ? Icons.watch : Icons.watch_off_outlined,
              color: _isConnected ? AppColors.primaryGreen : AppColors.warning,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isConnected ? 'Watch connected' : 'Watch not connected',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!_isConnected)
                    const Text(
                      'Tap to connect your watch',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (!_isConnected)
              const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildUploadNudgeCard() {
    return GestureDetector(
      onTap: () => widget.onNavigateToTab(3),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.secondaryCoral.withOpacity(0.10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.secondaryCoral.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_upload_outlined, color: AppColors.secondaryCoral, size: 22),
            const SizedBox(width: 14),
            const Expanded(
              child: Text(
                'You have data that hasn\'t been sent to the research server yet',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildCollectionProgressCard() {
    final progress = (_coverageHours / _collectionGoalHours).clamp(0.0, 1.0);
    final isComplete = _coverageHours >= _collectionGoalHours;

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Data collected',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
              ),
              if (isComplete)
                Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: AppColors.primaryGreen, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      'Goal reached',
                      style: TextStyle(color: AppColors.primaryGreen, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: AppColors.background,
              valueColor: AlwaysStoppedAnimation<Color>(
                isComplete ? AppColors.primaryGreen : AppColors.secondaryCoral,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$_coverageHours of $_collectionGoalHours hours',
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildRiskHeroCard() {
    // State 1: report ready — compact summary + link to the full report
    if (_report != null) {
      return _buildReportReadyCard(_report!);
    }

    // State 2: 48h reached, report not computed yet
    if (_coverageHours >= _collectionGoalHours || _generatingReport) {
      return _buildGeneratingCard();
    }

    // State 3: not connected, nothing collected yet
    if (!_isConnected && _totalReadings == 0) {
      return _buildConnectPromptCard();
    }

    // State 4: still collecting toward the 48h goal
    return _buildCollectingCard();
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
            'Connect your watch to start monitoring.\nYour full cardiac risk report becomes available '
            'after 48 hours of continuous data collection.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildCollectingCard() {
    final progress = (_coverageHours / _collectionGoalHours).clamp(0.0, 1.0);
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
                      'Cardiac Risk Report',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      'Collecting data…',
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
                '$_coverageHours / $_collectionGoalHours hours',
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
          const SizedBox(height: 10),
          const Text(
            'Your risk score is only computed once, from the full 48-hour '
            'session — this matches how the model was trained and evaluated.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneratingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
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
          const CircularProgressIndicator(color: AppColors.primaryGreen),
          const SizedBox(height: 18),
          const Text(
            'Generating Your Report',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '48 hours of data collected — scoring your full session now.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildReportReadyCard(FinalReport report) {
    final color = _riskColor(report.riskLevel);
    final label = _riskLabel(report.riskLevel);
    final pct = (report.score * 100).round();

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
                'Cardiac Risk Report',
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
            tween: Tween(begin: 0.0, end: report.score),
            duration: const Duration(milliseconds: 1000),
            curve: Curves.easeOutCubic,
            builder: (context, animated, _) {
              return SizedBox(
                width: 200,
                height: 130,
                child: CustomPaint(
                  painter: _RiskGaugePainter(
                    progress: animated,
                    trackColor: Colors.grey.shade200,
                    fillColor: color,
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
                'Generated ${_formatTime(report.computedAt)} · from your full session',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
              ),
            ],
          ),

          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReportScreen(report: report)),
              ),
              icon: const Icon(Icons.description_outlined, size: 18),
              label: const Text('View Full Report'),
              style: OutlinedButton.styleFrom(
                foregroundColor: color,
                side: BorderSide(color: color.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
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
