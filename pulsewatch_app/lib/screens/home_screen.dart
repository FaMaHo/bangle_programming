import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/database_helper.dart';
import '../services/ble_service.dart';
import '../services/notification_service.dart';
import '../services/report_service.dart';
import '../services/server_service.dart';
import '../services/upload_consent_service.dart';
import 'report_screen.dart';
import 'settings_screen.dart';
import '../widgets/app_bottom_sheet.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Home dashboard — the first thing a user sees. Answers, at a glance:
/// is the watch connected, how much data have we collected toward the
/// 48h goal, and is there anything the user needs to go do (connect the
/// watch, upload data). Before the 48h goal is reached it also surfaces a
/// few real, already-computed facts (overnight HR, signal quality, wear
/// coverage, movement) so the screen has something honest to show besides
/// a bare progress number.
///
/// The cardiac risk score is only ever computed once, from the full 48h
/// session (see ReportService) — never from a short live window, which
/// isn't how the model was trained/evaluated and produced unreliable
/// high-risk false positives.
class HomeScreen extends StatefulWidget {
  final void Function(int tabIndex) onNavigateToTab;
  // Optional spotlight anchors for the new-signup coach-mark walkthrough
  // (see MainNavigation) — null outside that flow.
  final GlobalKey? watchStatusKey;
  final GlobalKey? progressCardKey;

  const HomeScreen({
    super.key,
    required this.onNavigateToTab,
    this.watchStatusKey,
    this.progressCardKey,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final BleService _bleService = BleService();
  final ServerService _server = ServerService.instance;

  bool _isConnected = false;
  int _coverageHours = 0; // distinct hours with data in the last 48h
  int _totalReadings = 0; // used only to detect the "connected, nothing collected yet" gap
  UploadHealth _uploadHealth = UploadHealth.ok;
  DateTime? _lastUpload;

  String? _displayName;
  int? _restingHR;
  int _signalQuality = 0;
  int _hoursWornToday = 0;
  int _gapsToday = 0;
  String _movementLabel = '--';
  String _movementCaption = 'Not enough data yet';

  static const _collectionGoalHours = 48;

  FinalReport? _report;
  bool _generatingReport = false;

  Timer? _statsTimer;
  Timer? _uploadHealthTimer;

  StreamSubscription? _connectionSubscription;

  @override
  void initState() {
    super.initState();

    NotificationService.initialize();
    _isConnected = _bleService.isConnected;
    _loadDisplayName();
    _loadStats();
    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) => _loadStats());

    // Separate, much less frequent timer: checkUploadHealth() makes a real
    // network call when there's pending data, which the 10s stats poll
    // above is far too tight an interval for.
    _loadUploadHealth();
    _uploadHealthTimer = Timer.periodic(const Duration(minutes: 5), (_) => _loadUploadHealth());

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

  Future<void> _loadDisplayName() async {
    final username = await AuthService.instance.getUsername();
    if (!mounted || username == null || username.trim().isEmpty) return;
    final first = username.trim().split(RegExp(r'[ _.]+')).first;
    final capitalized = first.isEmpty ? first : '${first[0].toUpperCase()}${first.substring(1)}';
    setState(() => _displayName = capitalized);
  }

  /// Only meaningful for users who've opted into automatic upload — if
  /// they haven't, there's no expectation of automatic delivery to fall
  /// short of, so there's nothing to warn about here.
  Future<void> _loadUploadHealth() async {
    final consented = await UploadConsentService.instance.hasConsented();
    final health = consented ? await _server.checkUploadHealth() : UploadHealth.ok;
    if (mounted) setState(() => _uploadHealth = health);
  }

  /// Offered once, the first time we see a successful connection where the
  /// app isn't already exempted — battery optimization is what silently
  /// throttled/killed the background connection during earlier testing.
  Future<void> _maybeShowBatteryExemptionPrompt() async {
    if (!await _bleService.needsBatteryExemptionPrompt()) return;
    if (!mounted) return;

    final proceed = await showAppConfirmSheet(
      context: context,
      icon: Icons.battery_charging_full_rounded,
      iconColor: AppColors.primaryGreen,
      title: 'Keep recording reliable',
      body: 'Your phone\'s battery settings can pause PulseWatch in the '
          'background, which can interrupt your 48-hour session. On the '
          'next screen, choose "Allow" (or "Unrestricted") so recording '
          'keeps running the whole time.',
      primaryLabel: 'Continue',
      secondaryLabel: 'Not now',
    );

    if (proceed == true) {
      await _bleService.requestBatteryExemption();
    }
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
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));

    final coverage = await _db.getHourlyMeanHR(_collectionGoalHours);
    final totalReadings = await _db.getTotalReadings();
    final lastUpload = await _server.getLastUploadTime();

    final nocturnal = await _db.getNocturnalHR();
    final avgConfidence = await _db.getAvgConfidence(sinceMillis: todayStart.millisecondsSinceEpoch);
    final hoursToday = await _db.getHoursWithDataSince(todayStart);
    final gapsToday = await _db.findGaps(
      threshold: const Duration(minutes: 30),
      since: todayStart,
      limit: 50,
    );

    final yesterdaySameClock = yesterdayStart.add(Duration(hours: now.hour, minutes: now.minute));
    final todayMovement = await _db.getAverageMovementIntensity(start: todayStart, end: now);
    final yesterdayMovement = await _db.getAverageMovementIntensity(
      start: yesterdayStart,
      end: yesterdaySameClock,
    );

    if (mounted) {
      setState(() {
        _coverageHours = coverage.length;
        _totalReadings = totalReadings;
        _lastUpload = lastUpload;

        _restingHR = nocturnal.isNotEmpty
            ? (nocturnal.reduce((a, b) => a + b) / nocturnal.length).round()
            : null;
        _signalQuality = avgConfidence;
        _hoursWornToday = hoursToday;
        _gapsToday = gapsToday.length;

        if (todayMovement == null || yesterdayMovement == null || yesterdayMovement < 0.001) {
          _movementLabel = '--';
          _movementCaption = 'Not enough data yet';
        } else {
          final ratio = todayMovement / yesterdayMovement;
          if (ratio > 1.1) {
            _movementLabel = 'More active';
          } else if (ratio < 0.9) {
            _movementLabel = 'Less active';
          } else {
            _movementLabel = 'About the same';
          }
          _movementCaption = 'Than yesterday, same time';
        }
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
    _uploadHealthTimer?.cancel();
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

  String _greeting() {
    final hour = DateTime.now().hour;
    final period = hour < 12 ? 'morning' : (hour < 17 ? 'afternoon' : 'evening');
    return _displayName == null ? 'Good $period' : 'Good $period, $_displayName';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          const SizedBox(height: 14),
          KeyedSubtree(key: widget.watchStatusKey, child: _buildStatusChip()),
          const SizedBox(height: 18),

          if (_uploadHealth != UploadHealth.ok) ...[
            _buildUploadHealthBanner(),
            const SizedBox(height: 16),
          ],

          KeyedSubtree(key: widget.progressCardKey, child: _buildMainSection()),

          if (_report == null) ...[
            const SizedBox(height: 14),
            _buildFactsGrid(),
          ],

          const SizedBox(height: 14),
          _buildSyncFootnote(),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_getFormattedDate(), style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              const SizedBox(height: 2),
              Text(_greeting(), style: Theme.of(context).textTheme.headlineMedium),
            ],
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(color: AppColors.cardBackground, shape: BoxShape.circle),
            child: const Icon(Icons.settings_outlined, color: AppColors.textSecondary, size: 18),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusChip() {
    final color = _isConnected ? AppColors.primaryGreen : AppColors.warning;
    final isColdStart = _isConnected && _coverageHours == 0;
    return GestureDetector(
      onTap: _isConnected ? null : () => widget.onNavigateToTab(2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            isColdStart
                ? _PulsingDot(size: 7, color: color)
                : Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(
              _isConnected ? 'Watch connected' : 'Tap to connect watch',
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  // Deliberately quiet in the normal case: this only appears when
  // checkUploadHealth() finds something actually wrong (no connection, or
  // a real backlog) — not on every ordinary gap between auto-upload
  // cycles, which used to make this show up almost constantly.
  Widget _buildUploadHealthBanner() {
    final isBacklog = _uploadHealth == UploadHealth.backlogRisk;
    final icon = isBacklog ? Icons.cloud_off_rounded : Icons.wifi_off_rounded;
    final text = isBacklog
        ? 'Your data hasn\'t reached the server in a while — tap to upload manually.'
        : 'Can\'t reach the research server — check your internet connection.';

    return GestureDetector(
      onTap: isBacklog ? () => widget.onNavigateToTab(3) : null,
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
            Icon(icon, color: AppColors.secondaryCoral, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ),
            if (isBacklog) const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildMainSection() {
    // State 1: report ready — compact summary + link to the full report
    if (_report != null) {
      return _buildReportReadyCard(_report!);
    }

    // State 2: 48h reached, report not computed yet
    if (_coverageHours >= _collectionGoalHours || _generatingReport) {
      return _buildGeneratingCard();
    }

    // State 3: still collecting toward (or hasn't started) the 48h goal
    return _buildProgressHeroCard();
  }

  Widget _buildProgressHeroCard() {
    // The gap right after connecting: no crash, nothing broken, just not
    // enough data yet for the ring to mean anything — without some signal
    // here it reads as "is this working?" instead of "this is normal".
    if (_isConnected && _coverageHours == 0) {
      final hasReading = _totalReadings > 0;
      return _heroCardChrome(
        leading: const _PulsingHeartRing(size: 84),
        title: hasReading ? 'You\'re recording' : 'Waiting for your first reading',
        caption: hasReading
            ? 'Keep wearing your watch — your first hour of data will show up soon.'
            : 'Keep your watch nearby — it syncs in the background every 15–20 '
                'minutes, so your first reading can take a little while to show up.',
      );
    }

    final progress = (_coverageHours / _collectionGoalHours).clamp(0.0, 1.0);
    final remaining = _collectionGoalHours - _coverageHours;
    final started = _coverageHours > 0 || _isConnected;

    final String title;
    final String caption;
    if (!started) {
      title = 'Ready when you are';
      caption = 'Connect your watch to start your 48-hour session. Your cardiac '
          'risk report unlocks once it\'s complete.';
    } else if (progress < 0.5) {
      title = 'Just getting started';
      caption = '$_coverageHours of 48 hours recorded so far. Keep wearing the '
          'watch through today and tonight.';
    } else {
      title = 'Past the halfway point';
      caption = 'About $remaining hours left, including tonight. Every hour you '
          'wear it sharpens the picture.';
    }

    return _heroCardChrome(
      leading: SizedBox(
        width: 84,
        height: 84,
        child: CustomPaint(
          painter: _ProgressRingPainter(
            progress: progress,
            trackColor: AppColors.primaryGreen.withOpacity(0.18),
            fillColor: AppColors.primaryGreen,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$_coverageHours',
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const Text('of 48h', style: TextStyle(color: AppColors.textSecondary, fontSize: 10)),
              ],
            ),
          ),
        ),
      ),
      title: title,
      caption: caption,
    );
  }

  Widget _heroCardChrome({required Widget leading, required String title, required String caption}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.primaryGreen.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(caption, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFactsGrid() {
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildFactTile(
                  icon: Icons.favorite_border,
                  iconColor: const Color(0xFF993556),
                  iconBg: const Color(0xFFFBEAF0),
                  value: _restingHR != null ? '$_restingHR' : '--',
                  unit: _restingHR != null ? 'bpm' : '',
                  label: 'Resting heart rate, last night',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildFactTile(
                  icon: Icons.graphic_eq,
                  iconColor: const Color(0xFF0F6E56),
                  iconBg: const Color(0xFFE1F5EE),
                  value: _signalQuality > 0 ? '$_signalQuality' : '--',
                  unit: _signalQuality > 0 ? '%' : '',
                  label: 'Signal quality today',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildFactTile(
                  icon: Icons.check_circle_outline,
                  iconColor: const Color(0xFF3B6D11),
                  iconBg: const Color(0xFFEAF3DE),
                  value: '$_hoursWornToday',
                  unit: 'h',
                  label: _gapsToday == 0
                      ? 'Worn today, no gaps'
                      : 'Worn today, $_gapsToday gap${_gapsToday == 1 ? '' : 's'}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildFactTile(
                  icon: Icons.directions_walk,
                  iconColor: const Color(0xFF3C3489),
                  iconBg: const Color(0xFFEEEDFE),
                  value: _movementLabel,
                  unit: '',
                  label: _movementCaption,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFactTile({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String value,
    required String unit,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.cardBackground, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: iconColor, size: 15),
          ),
          const SizedBox(height: 10),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700),
                ),
                if (unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w400),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 11, height: 1.3),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSyncFootnote() {
    return Row(
      children: [
        Icon(Icons.sync, size: 13, color: AppColors.textSecondary.withOpacity(0.7)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _syncStatusText(),
            style: TextStyle(color: AppColors.textSecondary.withOpacity(0.7), fontSize: 12),
          ),
        ),
      ],
    );
  }

  String _syncStatusText() {
    // Anything worth surfacing beyond "everything's fine" already has its
    // own banner above (_buildUploadHealthBanner) — this line just reports
    // the last-known-good sync time, not problem states.
    if (_lastUpload == null) {
      return 'Syncs automatically once your watch connects.';
    }
    final mins = DateTime.now().difference(_lastUpload!).inMinutes;
    if (mins < 1) return 'Syncs automatically · synced just now';
    if (mins < 60) return 'Syncs automatically · synced $mins min ago';
    final hours = (mins / 60).floor();
    return 'Syncs automatically · synced ${hours}h ago';
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

  String _getFormattedDate() {
    final now = DateTime.now();
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'];
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}';
  }
}

class _ProgressRingPainter extends CustomPainter {
  final double progress;
  final Color trackColor;
  final Color fillColor;

  const _ProgressRingPainter({
    required this.progress,
    required this.trackColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - 8) / 2;
    const strokeWidth = 8.0;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
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
  bool shouldRepaint(_ProgressRingPainter old) =>
      old.progress != progress || old.fillColor != fillColor;
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

/// A small "recording live" indicator — a solid dot with a ring that
/// expands and fades outward on a loop. No numbers, just proof the
/// connection is alive. Used in the status chip during the cold-start gap
/// (connected, but not enough data yet for the hour-coverage ring to mean
/// anything).
class _PulsingDot extends StatefulWidget {
  final double size;
  final Color color;

  const _PulsingDot({required this.size, required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size * 3,
      height: widget.size * 3,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: (1 - t) * 0.6,
                child: Transform.scale(
                  scale: 1 + t * 2.2,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
                  ),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The hero-card version of the same "we're listening" cue: a breathing
/// ring around a gently pulsing heart icon. Deliberately shows no number —
/// this is proof-of-connection, not a live vital, so it can't be mistaken
/// for a health reading or the (48h-gated) risk score.
class _PulsingHeartRing extends StatefulWidget {
  final double size;

  const _PulsingHeartRing({required this.size});

  @override
  State<_PulsingHeartRing> createState() => _PulsingHeartRingState();
}

class _PulsingHeartRingState extends State<_PulsingHeartRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final heartScale = 0.92 + (math.sin(t * math.pi) * 0.08);
          return Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: (1 - t).clamp(0.0, 1.0) * 0.5,
                child: Transform.scale(
                  scale: 1 + t * 0.35,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.primaryGreen, width: 2),
                    ),
                  ),
                ),
              ),
              Container(
                width: widget.size * 0.72,
                height: widget.size * 0.72,
                decoration: BoxDecoration(color: AppColors.primaryGreen.withOpacity(0.15), shape: BoxShape.circle),
              ),
              Transform.scale(
                scale: heartScale,
                child: Icon(Icons.favorite_rounded, color: AppColors.primaryGreen, size: widget.size * 0.32),
              ),
            ],
          );
        },
      ),
    );
  }
}
