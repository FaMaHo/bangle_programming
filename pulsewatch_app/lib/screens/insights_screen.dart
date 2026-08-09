import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';

enum _WearStatus { good, weak, gap }

class _HourSegment {
  final int hourIndex; // 0-based, elapsed hours from the start of what we're showing
  final DateTime hourStart;
  final _WearStatus status;
  final double? meanBpm;
  final double? meanConfidence;

  _HourSegment({
    required this.hourIndex,
    required this.hourStart,
    required this.status,
    this.meanBpm,
    this.meanConfidence,
  });
}

/// A contiguous run of hours sharing the same [status] — the unit both the
/// tap targets and the insight message operate on, since "one 3-hour gap"
/// is what a person actually wants to know, not three separate 1-hour gaps.
class _Run {
  final _WearStatus status;
  final int startIndex;
  final int endIndexExclusive;
  final DateTime startTime;
  final DateTime endTime;

  _Run({
    required this.status,
    required this.startIndex,
    required this.endIndexExclusive,
    required this.startTime,
    required this.endTime,
  });

  int get hourCount => endIndexExclusive - startIndex;

  bool get overlapsSleepHours {
    for (var i = startIndex; i < endIndexExclusive; i++) {
      final hour = startTime.add(Duration(hours: i - startIndex)).hour;
      if (hour >= 22 || hour < 7) return true;
    }
    return false;
  }
}

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  final DatabaseHelper _db = DatabaseHelper.instance;

  static const _weakSignalThreshold = 70.0; // confidence 0-100
  static const _minHoursForInsight = 6;

  bool _loading = true;
  List<_HourSegment> _segments = [];
  List<_Run> _runs = [];
  int _hoursWorn = 0;
  int _gapRunCount = 0;
  int _avgSignal = 0;
  double _minBpm = 0;
  double _maxBpm = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final samples = await _db.getHourlySamples(48);

    if (samples.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final nowHourBucket = DateTime.now().millisecondsSinceEpoch ~/ 3600000;
    final firstHourBucket = samples.first.hourBucket;
    // Only shows the span that's actually elapsed since the first reading
    // in this 48h window — a blind "always 48h wide" scale would paint
    // every hour before the watch was ever connected as a false "gap".
    final totalHours = (nowHourBucket - firstHourBucket + 1).clamp(1, 48);
    final startHourBucket = nowHourBucket - totalHours + 1;

    final byBucket = {for (final s in samples) s.hourBucket: s};
    final segments = <_HourSegment>[];
    for (var i = 0; i < totalHours; i++) {
      final bucket = startHourBucket + i;
      final sample = byBucket[bucket];
      final hourStart = DateTime.fromMillisecondsSinceEpoch(bucket * 3600000);
      if (sample == null || sample.count == 0) {
        segments.add(_HourSegment(hourIndex: i, hourStart: hourStart, status: _WearStatus.gap));
      } else {
        final conf = sample.meanConfidence ?? 100;
        final status = conf < _weakSignalThreshold ? _WearStatus.weak : _WearStatus.good;
        segments.add(_HourSegment(
          hourIndex: i,
          hourStart: hourStart,
          status: status,
          meanBpm: sample.meanBpm,
          meanConfidence: sample.meanConfidence,
        ));
      }
    }

    final runs = _computeRuns(segments);

    final worn = segments.where((s) => s.status != _WearStatus.gap).length;
    final gapRuns = runs.where((r) => r.status == _WearStatus.gap).length;
    final confidences = segments.map((s) => s.meanConfidence).whereType<double>().toList();
    final avgSignal = confidences.isEmpty
        ? 0
        : (confidences.reduce((a, b) => a + b) / confidences.length).round();
    final bpms = segments.map((s) => s.meanBpm).whereType<double>().toList();
    final minBpm = bpms.isEmpty ? 0.0 : bpms.reduce((a, b) => a < b ? a : b);
    final maxBpm = bpms.isEmpty ? 0.0 : bpms.reduce((a, b) => a > b ? a : b);

    if (mounted) {
      setState(() {
        _segments = segments;
        _runs = runs;
        _hoursWorn = worn;
        _gapRunCount = gapRuns;
        _avgSignal = avgSignal;
        _minBpm = minBpm;
        _maxBpm = maxBpm;
        _loading = false;
      });
    }
  }

  List<_Run> _computeRuns(List<_HourSegment> segments) {
    final runs = <_Run>[];
    var i = 0;
    while (i < segments.length) {
      var j = i + 1;
      while (j < segments.length && segments[j].status == segments[i].status) {
        j++;
      }
      runs.add(_Run(
        status: segments[i].status,
        startIndex: i,
        endIndexExclusive: j,
        startTime: segments[i].hourStart,
        endTime: segments[j - 1].hourStart.add(const Duration(hours: 1)),
      ));
      i = j;
    }
    return runs;
  }

  String _formatHour(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h $ampm';
  }

  String _formatHourRange(DateTime start, DateTime end) {
    final startAmPm = start.hour < 12 ? 'AM' : 'PM';
    final endAmPm = end.hour < 12 ? 'AM' : 'PM';
    final startH = start.hour % 12 == 0 ? 12 : start.hour % 12;
    final endH = end.hour % 12 == 0 ? 12 : end.hour % 12;
    if (startAmPm == endAmPm) return '$startH–$endH $endAmPm';
    return '$startH $startAmPm–$endH $endAmPm';
  }

  String _dayLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'yesterday';
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return weekdays[dt.weekday - 1];
  }

  /// Picks the single most useful thing to say about this session — a
  /// notable gap first, then notable weak signal, then appreciation if
  /// neither applies. Never lists every event; a footnote covers "there
  /// were more" without turning this into a report.
  ({IconData icon, Color iconColor, Color bg, Color textColor, String text})? _buildInsight() {
    if (_segments.length < _minHoursForInsight) return null;

    final gapRuns = _runs.where((r) => r.status == _WearStatus.gap).toList()
      ..sort((a, b) => b.hourCount.compareTo(a.hourCount));
    final weakRuns = _runs.where((r) => r.status == _WearStatus.weak).toList()
      ..sort((a, b) => b.hourCount.compareTo(a.hourCount));

    if (gapRuns.isNotEmpty) {
      final run = gapRuns.first;
      final duration = run.hourCount == 1 ? '1-hour' : '${run.hourCount}-hour';
      final timeRange = _formatHourRange(run.startTime, run.endTime);
      final day = _dayLabel(run.startTime);
      final tip = run.overlapsSleepHours
          ? 'If it slipped off overnight, tightening the strap a notch before bed usually helps it stay snug.'
          : "If you took it off (shower, charging, workout), that's completely fine — just try to get it back on soon after so we don't miss too much.";
      final extra = gapRuns.length > 1
          ? ' (and ${gapRuns.length - 1} other shorter gap${gapRuns.length > 2 ? 's' : ''})'
          : '';
      return (
        icon: Icons.chat_bubble_outline_rounded,
        iconColor: const Color(0xFF534AB7),
        bg: const Color(0xFFEEEDFE),
        textColor: const Color(0xFF26215C),
        text: 'We noticed a $duration gap around $timeRange $day$extra. $tip',
      );
    }

    if (weakRuns.isNotEmpty) {
      final run = weakRuns.first;
      final timeRange = _formatHourRange(run.startTime, run.endTime);
      final day = _dayLabel(run.startTime);
      return (
        icon: Icons.chat_bubble_outline_rounded,
        iconColor: const Color(0xFF534AB7),
        bg: const Color(0xFFEEEDFE),
        textColor: const Color(0xFF26215C),
        text: 'Signal was a bit weak around $timeRange $day. A snugger fit — about a '
            "finger's width of slack — usually helps the sensor stay locked on.",
      );
    }

    return (
      icon: Icons.favorite_rounded,
      iconColor: AppColors.primaryGreen,
      bg: AppColors.primaryGreen.withOpacity(0.10),
      textColor: AppColors.textPrimary,
      text: "Great consistency — you've worn the watch for the whole session with a "
          'strong signal throughout. Keep it up!',
    );
  }

  void _showRunDetail(_Run run) {
    final label = switch (run.status) {
      _WearStatus.gap => 'Not worn',
      _WearStatus.weak => 'Weak signal',
      _WearStatus.good => 'Good signal',
    };
    final duration = run.hourCount == 1 ? '1 hour' : '${run.hourCount} hours';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$label • ${_formatHourRange(run.startTime, run.endTime)} ${_dayLabel(run.startTime)} • $duration',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Insights', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 24),
          if (_loading)
            const Center(child: Padding(
              padding: EdgeInsets.only(top: 60),
              child: CircularProgressIndicator(color: AppColors.primaryGreen),
            ))
          else if (_segments.isEmpty)
            _buildEmptyState()
          else ...[
            _buildTrendCard(),
            const SizedBox(height: 10),
            _buildStatsRow(),
            Builder(builder: (context) {
              final insight = _buildInsight();
              if (insight == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _buildInsightCard(insight),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.show_chart_rounded, color: AppColors.textSecondary.withOpacity(0.4), size: 40),
          const SizedBox(height: 16),
          const Text(
            'Nothing to show yet',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Once you start recording, your heart rate trend and wear time will show up here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildTrendCard() {
    final first = _segments.first.hourStart;
    final mid = _segments[_segments.length ~/ 2].hourStart;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Heart rate', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              Text(
                _segments.length == 1 ? '1 hour' : '${_segments.length}h session',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 100,
            width: double.infinity,
            child: CustomPaint(
              painter: _HrTrendPainter(segments: _segments, minBpm: _minBpm, maxBpm: _maxBpm),
            ),
          ),
          const SizedBox(height: 4),
          _buildWearTimeline(),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatHour(first), style: TextStyle(fontSize: 10, color: AppColors.textSecondary.withOpacity(0.7))),
              if (_segments.length > 2)
                Text(_formatHour(mid), style: TextStyle(fontSize: 10, color: AppColors.textSecondary.withOpacity(0.7))),
              Text('Now', style: TextStyle(fontSize: 10, color: AppColors.textSecondary.withOpacity(0.7))),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _legendDot(AppColors.primaryGreen, 'Good signal'),
              const SizedBox(width: 14),
              _legendDot(AppColors.warning, 'Weak signal'),
              const SizedBox(width: 14),
              _legendDot(Colors.grey.shade300, 'Not worn'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _buildWearTimeline() {
    return SizedBox(
      height: 14,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Row(
          children: _runs.map((run) {
            final color = switch (run.status) {
              _WearStatus.good => AppColors.primaryGreen,
              _WearStatus.weak => AppColors.warning,
              _WearStatus.gap => Colors.grey.shade300,
            };
            return Expanded(
              flex: run.hourCount,
              child: GestureDetector(
                onTap: run.status == _WearStatus.good ? null : () => _showRunDetail(run),
                child: Container(color: color),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: [
        Expanded(child: _statChip(Icons.check_circle_outline, const Color(0xFF3B6D11), const Color(0xFFEAF3DE), '$_hoursWorn', 'h', 'Worn')),
        const SizedBox(width: 8),
        Expanded(child: _statChip(Icons.warning_amber_rounded, const Color(0xFF854F0B), const Color(0xFFFAEEDA), '$_gapRunCount', '', 'Gaps')),
        const SizedBox(width: 8),
        Expanded(child: _statChip(Icons.graphic_eq, const Color(0xFF0F6E56), const Color(0xFFE1F5EE), _avgSignal > 0 ? '$_avgSignal' : '--', _avgSignal > 0 ? '%' : '', 'Avg signal')),
      ],
    );
  }

  Widget _statChip(IconData icon, Color iconColor, Color iconBg, String value, String unit, String label) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.cardBackground, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(7)),
            child: Icon(icon, size: 13, color: iconColor),
          ),
          const SizedBox(height: 8),
          RichText(
            text: TextSpan(children: [
              TextSpan(text: value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w500)),
              if (unit.isNotEmpty) TextSpan(text: unit, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
            ]),
          ),
          Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildInsightCard(({IconData icon, Color iconColor, Color bg, Color textColor, String text}) insight) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: insight.bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26, height: 26,
            decoration: const BoxDecoration(color: AppColors.cardBackground, shape: BoxShape.circle),
            child: Icon(insight.icon, size: 14, color: insight.iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(insight.text, style: TextStyle(fontSize: 12.5, color: insight.textColor, height: 1.5)),
          ),
        ],
      ),
    );
  }
}

/// Draws the HR line as one polyline per contiguous run of non-gap hours —
/// gaps show as an actual break in the line rather than a straight
/// connector across missing data, matching the wear timeline underneath.
class _HrTrendPainter extends CustomPainter {
  final List<_HourSegment> segments;
  final double minBpm;
  final double maxBpm;

  _HrTrendPainter({required this.segments, required this.minBpm, required this.maxBpm});

  @override
  void paint(Canvas canvas, Size size) {
    if (segments.isEmpty) return;

    final n = segments.length;
    final xStep = n <= 1 ? size.width : size.width / (n - 1).clamp(1, 1 << 30);
    final range = (maxBpm - minBpm).clamp(1, double.infinity);
    const topPad = 6.0, bottomPad = 6.0;
    final plotHeight = size.height - topPad - bottomPad;

    double xFor(int i) => n <= 1 ? size.width / 2 : i * xStep;
    double yFor(double bpm) => topPad + plotHeight - ((bpm - minBpm) / range) * plotHeight;

    // Night shading behind the line — anything from 10pm to 7am local time.
    final nightPaint = Paint()..color = AppColors.textPrimary.withOpacity(0.035);
    int? nightStart;
    for (var i = 0; i < n; i++) {
      final isNight = segments[i].hourStart.hour >= 22 || segments[i].hourStart.hour < 7;
      if (isNight && nightStart == null) nightStart = i;
      if ((!isNight || i == n - 1) && nightStart != null) {
        final endI = isNight ? i : i - 1;
        canvas.drawRect(Rect.fromLTRB(xFor(nightStart), 0, xFor(endI) + (endI == n - 1 ? 0 : xStep), size.height), nightPaint);
        nightStart = null;
      }
    }

    final linePaint = Paint()
      ..color = const Color(0xFF993556)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    Path? current;
    for (var i = 0; i < n; i++) {
      final bpm = segments[i].meanBpm;
      if (bpm == null) {
        if (current != null) {
          canvas.drawPath(current, linePaint);
          current = null;
        }
        continue;
      }
      final point = Offset(xFor(i), yFor(bpm));
      if (current == null) {
        current = Path()..moveTo(point.dx, point.dy);
      } else {
        current.lineTo(point.dx, point.dy);
      }
    }
    if (current != null) canvas.drawPath(current, linePaint);
  }

  @override
  bool shouldRepaint(_HrTrendPainter old) =>
      old.segments != segments || old.minBpm != minBpm || old.maxBpm != maxBpm;
}
