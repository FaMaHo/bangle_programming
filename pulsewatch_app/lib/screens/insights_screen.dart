import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/loading_state.dart';

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

/// One 30-min bucket for the HR trend chart — a finer resolution than
/// _HourSegment (which the wear timeline uses) so a short session still
/// has enough points to look like a real curve. min/max come along so the
/// chart can show the actual spread within each bucket, not just a
/// flattened mean.
class _ChartBucket {
  final int index;
  final DateTime start;
  final double? meanBpm;
  final double? minBpm;
  final double? maxBpm;

  _ChartBucket({required this.index, required this.start, this.meanBpm, this.minBpm, this.maxBpm});
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
  List<_ChartBucket> _chartBuckets = [];
  double _hrLowest = 0;
  double _hrTypical = 0;
  double _hrPeak = 0;
  // Whether the window's right edge is recent enough to still call "Now" —
  // see _loadImpl's isLive. When false, the trend card's trailing axis
  // label shows the actual time of the last reading instead.
  bool _isLive = true;
  DateTime _windowEndTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _loadImpl();
    } catch (_) {
      // A failed query should show the empty state, not spin forever —
      // whatever went wrong, the user should never be stuck looking at a
      // loading indicator with no way forward.
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadImpl() async {
    // Anchored to the actual data — the last real reading — rather than
    // ReportService's session-start bookkeeping (tried that; it broke the
    // moment that marker moved for reasons unrelated to what data actually
    // exists, e.g. tapping "Start a new recording", and Insights went
    // blank despite days of real history sitting right there) or a rolling
    // "now" (the original bug: once a session went quiet, the window kept
    // stretching an ever-growing empty gap out to the current moment
    // instead of ever settling). Ending the window at the last reading
    // instead of "now" fixes both: a live session's last reading is always
    // recent, so this reads as "now" in practice, while a session that's
    // gone quiet just freezes right where the real data stopped.
    final lastReading = await _db.getLastReadingTime();
    if (lastReading == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final firstReading = await _db.getFirstReadingTime() ?? lastReading;
    final now = DateTime.now();
    final effectiveEnd = lastReading;
    // "Live" only when the last reading is recent enough that this is
    // plausibly still an active session — purely a label decision (see
    // _buildTrendCard's trailing axis label), not part of the window math.
    final isLive = now.difference(lastReading) < const Duration(minutes: 5);

    final firstReadingHourBucket = firstReading.millisecondsSinceEpoch ~/ 3600000;
    final endHourBucket = effectiveEnd.millisecondsSinceEpoch ~/ 3600000;
    // Only shows the span that's actually elapsed since the first reading,
    // capped at 48h — a blind "always 48h wide" scale would paint every
    // hour before the watch was ever connected as a false "gap", and
    // capping means a session that's been running for weeks still only
    // ever shows its most recent 48h, exactly like the report itself.
    final totalHours = (endHourBucket - firstReadingHourBucket + 1).clamp(1, 48);
    final windowStartHourBucket = endHourBucket - totalHours + 1;

    final samples = await _db.getHourlySamples(
      48,
      since: DateTime.fromMillisecondsSinceEpoch(windowStartHourBucket * 3600000),
      before: effectiveEnd.add(const Duration(seconds: 1)),
    );

    if (samples.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // The HR chart samples at a finer resolution than the hourly wear
    // timeline below — enough points to look like a real curve even early
    // in a session — but spans the exact same elapsed window. Fetched here
    // (rather than after the timeline) because the wear timeline also
    // needs it: an hourly aggregate alone can't see a gap shorter than a
    // full hour — if the watch comes back on within the same clock hour,
    // that hour's total reading count is still nonzero and reads as fully
    // "worn". Cross-checking against these finer buckets catches that.
    const bucketMinutes = 30;
    const bucketMs = bucketMinutes * 60000;
    final rangeSamples = await _db.getHrRangeSamples(
      48,
      bucketMinutes: bucketMinutes,
      since: DateTime.fromMillisecondsSinceEpoch(windowStartHourBucket * 3600000),
      before: effectiveEnd.add(const Duration(seconds: 1)),
    );
    final bucketsPerHour = 60 ~/ bucketMinutes;
    final coveredBucketsByHour = <int, int>{};
    for (final s in rangeSamples) {
      if (s.count == 0) continue;
      final hourBucket = s.bucketStart.millisecondsSinceEpoch ~/ 3600000;
      coveredBucketsByHour[hourBucket] = (coveredBucketsByHour[hourBucket] ?? 0) + 1;
    }

    final byBucket = {for (final s in samples) s.hourBucket: s};
    final segments = <_HourSegment>[];
    for (var i = 0; i < totalHours; i++) {
      final bucket = windowStartHourBucket + i;
      final sample = byBucket[bucket];
      final hourStart = DateTime.fromMillisecondsSinceEpoch(bucket * 3600000);
      final fullyCovered = (coveredBucketsByHour[bucket] ?? 0) >= bucketsPerHour;
      if (sample == null || sample.count == 0 || !fullyCovered) {
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

    final totalBuckets = totalHours * bucketsPerHour;
    final endBucketIndex = effectiveEnd.millisecondsSinceEpoch ~/ bucketMs;
    final startBucketIndex = endBucketIndex - totalBuckets + 1;
    final rangeByBucket = {
      for (final s in rangeSamples) s.bucketStart.millisecondsSinceEpoch ~/ bucketMs: s,
    };
    final chartBuckets = <_ChartBucket>[];
    for (var i = 0; i < totalBuckets; i++) {
      final bucketIdx = startBucketIndex + i;
      final sample = rangeByBucket[bucketIdx];
      final bucketStart = DateTime.fromMillisecondsSinceEpoch(bucketIdx * bucketMs);
      if (sample == null || sample.count == 0) {
        chartBuckets.add(_ChartBucket(index: i, start: bucketStart));
      } else {
        chartBuckets.add(_ChartBucket(
          index: i,
          start: bucketStart,
          meanBpm: sample.meanBpm,
          minBpm: sample.minBpm,
          maxBpm: sample.maxBpm,
        ));
      }
    }

    final allMins = chartBuckets.map((b) => b.minBpm).whereType<double>().toList();
    final allMaxs = chartBuckets.map((b) => b.maxBpm).whereType<double>().toList();
    final allMeans = chartBuckets.map((b) => b.meanBpm).whereType<double>().toList();
    final hrLowest = allMins.isEmpty ? 0.0 : allMins.reduce((a, b) => a < b ? a : b);
    final hrPeak = allMaxs.isEmpty ? 0.0 : allMaxs.reduce((a, b) => a > b ? a : b);
    final hrTypical = allMeans.isEmpty ? 0.0 : allMeans.reduce((a, b) => a + b) / allMeans.length;

    if (mounted) {
      setState(() {
        _segments = segments;
        _runs = runs;
        _hoursWorn = worn;
        _gapRunCount = gapRuns;
        _avgSignal = avgSignal;
        _chartBuckets = chartBuckets;
        _hrLowest = hrLowest;
        _hrTypical = hrTypical;
        _hrPeak = hrPeak;
        _isLive = isLive;
        _windowEndTime = effectiveEnd;
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

  /// Time-of-day window for a run, e.g. "2–3 PM" — but hourCount can run
  /// much longer than that suggests when start and end land at similar
  /// clock times a day or more apart (a run that's actually 25 hours long
  /// still has a start/end only an hour apart on the clock). Falls back to
  /// spelling out both endpoints with their own day label whenever they
  /// don't share a calendar day, instead of silently collapsing to a
  /// window that implies a much shorter gap than actually happened.
  String _formatWindow(DateTime start, DateTime end) {
    final sameDay = start.year == end.year && start.month == end.month && start.day == end.day;
    if (sameDay) return '${_formatHourRange(start, end)} ${_dayLabel(start)}';
    return '${_formatHour(start)} ${_dayLabel(start)} – ${_formatHour(end)} ${_dayLabel(end)}';
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
      final window = _formatWindow(run.startTime, run.endTime);
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
        text: 'We noticed a $duration gap around $window$extra. $tip',
      );
    }

    if (weakRuns.isNotEmpty) {
      final run = weakRuns.first;
      final window = _formatWindow(run.startTime, run.endTime);
      return (
        icon: Icons.chat_bubble_outline_rounded,
        iconColor: const Color(0xFF534AB7),
        bg: const Color(0xFFEEEDFE),
        textColor: const Color(0xFF26215C),
        text: 'Signal was a bit weak around $window. A snugger fit — about a '
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
          '$label • ${_formatWindow(run.startTime, run.endTime)} • $duration',
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
            const LoadingState(message: 'Crunching your heart rate data…')
          else if (_segments.isEmpty)
            _buildEmptyState()
          else ...[
            _buildTrendCard(),
            const SizedBox(height: 10),
            _buildHrStatsRow(),
            const SizedBox(height: 8),
            _buildWearStatsRow(),
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
              painter: _HrRangePainter(buckets: _chartBuckets),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildChartInfoButton(),
              const SizedBox(width: 10),
              _legendLine(const Color(0xFFD4537E), 'Range', dashed: true, thin: true),
              const SizedBox(width: 12),
              _legendLine(const Color(0xFF993556), 'Mean'),
              const SizedBox(width: 12),
              _legendSwatch(_HrRangePainter.nightShadeColor, 'Night hours'),
            ],
          ),
          const SizedBox(height: 14),
          _buildWearTimeline(),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatHour(first), style: TextStyle(fontSize: 10, color: AppColors.textSecondary.withOpacity(0.7))),
              if (_segments.length > 2)
                Text(_formatHour(mid), style: TextStyle(fontSize: 10, color: AppColors.textSecondary.withOpacity(0.7))),
              Text(
                _isLive ? 'Now' : _formatHour(_windowEndTime),
                style: TextStyle(fontSize: 10, color: AppColors.textSecondary.withOpacity(0.7)),
              ),
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

  Widget _legendLine(Color color, String label, {bool dashed = false, bool thin = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 6,
          child: CustomPaint(painter: _LegendLinePainter(color: color, dashed: dashed, thin: thin)),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
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

  // The night shading is deliberately very faint (see _HrRangePainter's
  // nightShadeColor) so it doesn't compete with the actual data — a bordered
  // swatch keeps that exact same fill legible at legend size instead of
  // bumping the opacity, which would make the legend lie about the chart.
  Widget _legendSwatch(Color fillColor, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 13,
          height: 10,
          decoration: BoxDecoration(
            color: fillColor,
            border: Border.all(color: AppColors.textSecondary.withOpacity(0.3), width: 0.75),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _buildChartInfoButton() {
    return Tooltip(
      message: 'See what this graph shows',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showChartInfoSheet(context),
        child: const Padding(
          padding: EdgeInsets.all(2),
          child: Icon(Icons.info_outline_rounded, size: 17, color: AppColors.textSecondary),
        ),
      ),
    );
  }

  void _showChartInfoSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Four explanation rows plus a title/intro can run taller than the
      // screen on smaller phones — AppBottomSheetChrome sizes to its child
      // (mainAxisSize.min), so without a cap + scroll view here the sheet
      // just overflows off the bottom of the screen instead of scrolling.
      builder: (context) => AppBottomSheetChrome(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
          child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSheetIconBadge(icon: Icons.show_chart_rounded, color: Color(0xFF993556)),
            const SizedBox(height: 16),
            const Text('About this chart', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            const Text(
              'Every half hour is summarized into a few numbers so the shape of your session is easy to read at a glance.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 18),
            _infoSheetRow(
              swatch: SizedBox(
                width: 18, height: 8,
                child: CustomPaint(painter: _LegendLinePainter(color: const Color(0xFFD4537E), dashed: true, thin: true)),
              ),
              title: 'Range',
              body: 'The shaded band and dashed edges mark the lowest and highest heart rate seen in that half hour — not just the average, so a brief spike or dip still shows up instead of getting smoothed away.',
            ),
            _infoSheetRow(
              swatch: SizedBox(
                width: 18, height: 8,
                child: CustomPaint(painter: _LegendLinePainter(color: const Color(0xFF993556), dashed: false, thin: false)),
              ),
              title: 'Mean',
              body: 'The solid line is the average heart rate for that half hour.',
            ),
            _infoSheetRow(
              swatch: Container(
                width: 18, height: 16,
                decoration: BoxDecoration(
                  color: _HrRangePainter.nightShadeColor,
                  border: Border.all(color: AppColors.textSecondary.withOpacity(0.3), width: 0.75),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              title: 'Night hours',
              body: 'The shaded background between 10 PM and 7 AM is just there to help you orient yourself in the timeline — it doesn\'t say anything about your data.',
            ),
            _infoSheetRow(
              swatch: SizedBox(
                width: 18, height: 16,
                child: CustomPaint(painter: _HatchSwatchPainter()),
              ),
              title: 'Hatched stretch',
              body: 'A diagonal-striped gap means no readings were captured during that time — usually the watch was off, out of range, or losing signal.',
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Got it'),
              ),
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoSheetRow({required Widget swatch, required String title, required String body}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 3), child: swatch),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(body, style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
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

  Widget _buildHrStatsRow() {
    final hasData = _hrPeak > 0;
    return Row(
      children: [
        Expanded(child: _statChip(Icons.arrow_downward_rounded, const Color(0xFF993556), const Color(0xFFFBEAF0), hasData ? '${_hrLowest.round()}' : '--', hasData ? ' bpm' : '', 'Lowest')),
        const SizedBox(width: 8),
        Expanded(child: _statChip(Icons.horizontal_rule_rounded, const Color(0xFF993556), const Color(0xFFFBEAF0), hasData ? '${_hrTypical.round()}' : '--', hasData ? ' bpm' : '', 'Typical')),
        const SizedBox(width: 8),
        Expanded(child: _statChip(Icons.arrow_upward_rounded, const Color(0xFF993556), const Color(0xFFFBEAF0), hasData ? '${_hrPeak.round()}' : '--', hasData ? ' bpm' : '', 'Peak')),
      ],
    );
  }

  Widget _buildWearStatsRow() {
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

/// Draws the HR chart as a smooth mean line with a shaded min/max band —
/// one such run per contiguous stretch of non-gap buckets, so a gap shows
/// as an actual hatched break rather than the line/band collapsing toward
/// zero (which would misleadingly read as "flatline" on a cardiac app).
/// Also draws three labeled reference gridlines so the shape has real
/// numbers attached to it, not just an unlabeled squiggle.
class _HrRangePainter extends CustomPainter {
  final List<_ChartBucket> buckets;

  _HrRangePainter({required this.buckets});

  // Shared with the legend swatch and the info sheet so all three stay in
  // sync if this ever changes, instead of three copies of the same color.
  static final Color nightShadeColor = AppColors.textPrimary.withOpacity(0.03);

  @override
  void paint(Canvas canvas, Size size) {
    if (buckets.isEmpty) return;

    final n = buckets.length;
    final xStep = n <= 1 ? size.width : size.width / (n - 1);
    double xFor(int i) => n <= 1 ? size.width / 2 : i * xStep;

    final mins = buckets.map((b) => b.minBpm).whereType<double>().toList();
    final maxs = buckets.map((b) => b.maxBpm).whereType<double>().toList();
    if (mins.isEmpty || maxs.isEmpty) return;

    final dataMin = mins.reduce((a, b) => a < b ? a : b);
    final dataMax = maxs.reduce((a, b) => a > b ? a : b);
    final pad = ((dataMax - dataMin) * 0.2).clamp(4.0, double.infinity);
    final plotMin = dataMin - pad;
    final plotMax = dataMax + pad;
    final range = (plotMax - plotMin).clamp(1, double.infinity);

    const topPad = 4.0, bottomPad = 4.0;
    final plotHeight = size.height - topPad - bottomPad;
    double yFor(double bpm) => topPad + plotHeight - ((bpm - plotMin) / range) * plotHeight;

    // Night shading behind everything else — anything from 10pm to 7am.
    final nightPaint = Paint()..color = nightShadeColor;
    int? nightStart;
    for (var i = 0; i < n; i++) {
      final isNight = buckets[i].start.hour >= 22 || buckets[i].start.hour < 7;
      if (isNight && nightStart == null) nightStart = i;
      if ((!isNight || i == n - 1) && nightStart != null) {
        final endI = isNight ? i : i - 1;
        canvas.drawRect(Rect.fromLTRB(xFor(nightStart), 0, xFor(endI) + (endI == n - 1 ? 0 : xStep), size.height), nightPaint);
        nightStart = null;
      }
    }

    // Three round-number reference lines spanning the padded range.
    double roundTo5(double v) => (v / 5).round() * 5;
    final refValues = <double>{
      roundTo5(plotMax - pad * 0.4),
      roundTo5((plotMin + plotMax) / 2),
      roundTo5(plotMin + pad * 0.4),
    };
    final gridPaint = Paint()
      ..color = AppColors.textSecondary.withOpacity(0.35)
      ..strokeWidth = 0.75;
    for (final v in refValues) {
      final y = yFor(v);
      _drawDashedLine(canvas, Offset(0, y), Offset(size.width, y), gridPaint, dash: 2, gap: 3);
      final tp = TextPainter(
        text: TextSpan(text: '${v.round()}', style: TextStyle(fontSize: 9, color: AppColors.textSecondary.withOpacity(0.85))),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width, (y - tp.height - 2).clamp(0, size.height - tp.height)));
    }

    // One band+mean run per contiguous stretch of real data; a hatched
    // panel fills the gaps in between.
    var i = 0;
    while (i < n) {
      if (buckets[i].meanBpm == null) {
        var j = i + 1;
        while (j < n && buckets[j].meanBpm == null) {
          j++;
        }
        final left = xFor(i);
        final right = xFor(j - 1) + (j - 1 == n - 1 ? 0 : xStep);
        _drawGapHatch(canvas, Rect.fromLTRB(left, 0, right, size.height));
        i = j;
        continue;
      }

      var j = i + 1;
      while (j < n && buckets[j].meanBpm != null) {
        j++;
      }
      final run = buckets.sublist(i, j);
      final upper = [for (final b in run) Offset(xFor(b.index), yFor(b.maxBpm!))];
      final lower = [for (final b in run) Offset(xFor(b.index), yFor(b.minBpm!))];
      final mean = [for (final b in run) Offset(xFor(b.index), yFor(b.meanBpm!))];

      if (run.length >= 2) {
        final fillPaint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [const Color(0xFFD4537E).withOpacity(0.26), const Color(0xFFD4537E).withOpacity(0.02)],
          ).createShader(Offset.zero & size);
        canvas.drawPath(_bandFillPath(upper, lower), fillPaint);

        final bandPaint = Paint()
          ..color = const Color(0xFFD4537E).withOpacity(0.65)
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
        canvas.drawPath(_dashPath(_smoothLinePath(upper), dash: 1.5, gap: 3), bandPaint);
        canvas.drawPath(_dashPath(_smoothLinePath(lower), dash: 1.5, gap: 3), bandPaint);
      }

      final meanPaint = Paint()
        ..color = const Color(0xFF993556)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(_smoothLinePath(mean), meanPaint);

      i = j;
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint, {required double dash, required double gap}) {
    final total = (p2 - p1).distance;
    if (total <= 0) return;
    final dir = (p2 - p1) / total;
    var d = 0.0;
    while (d < total) {
      final start = p1 + dir * d;
      final end = p1 + dir * (d + dash).clamp(0, total);
      canvas.drawLine(start, end, paint);
      d += dash + gap;
    }
  }

  void _drawGapHatch(Canvas canvas, Rect rect) {
    if (rect.width <= 0) return;
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(rect, Paint()..color = AppColors.cardBackground);
    final linePaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 2.5;
    const spacing = 6.0;
    for (var x = rect.left - rect.height; x < rect.right; x += spacing) {
      canvas.drawLine(Offset(x, rect.bottom), Offset(x + rect.height, rect.top), linePaint);
    }
    canvas.restore();
  }

  /// Catmull-Rom-through-Bezier smoothing — gives a natural curve through
  /// the data points instead of the angular "connect the dots" look of
  /// straight line segments, which is especially noticeable with only a
  /// handful of points early in a session.
  void _appendSmoothCurve(Path path, List<Offset> points) {
    if (points.length < 2) {
      if (points.isNotEmpty) path.lineTo(points.first.dx, points.first.dy);
      return;
    }
    for (var k = 0; k < points.length - 1; k++) {
      final p0 = k == 0 ? points[k] : points[k - 1];
      final p1 = points[k];
      final p2 = points[k + 1];
      final p3 = k + 2 < points.length ? points[k + 2] : p2;
      final cp1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
      final cp2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }
  }

  Path _smoothLinePath(List<Offset> points) {
    final path = Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.dx, points.first.dy);
    _appendSmoothCurve(path, points);
    return path;
  }

  Path _bandFillPath(List<Offset> upper, List<Offset> lower) {
    final path = Path();
    if (upper.isEmpty || lower.isEmpty) return path;
    path.moveTo(upper.first.dx, upper.first.dy);
    _appendSmoothCurve(path, upper);
    final reversedLower = lower.reversed.toList();
    path.lineTo(reversedLower.first.dx, reversedLower.first.dy);
    _appendSmoothCurve(path, reversedLower);
    path.close();
    return path;
  }

  Path _dashPath(Path source, {required double dash, required double gap}) {
    final dashed = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      var draw = true;
      while (distance < metric.length) {
        final len = draw ? dash : gap;
        final next = (distance + len).clamp(0.0, metric.length);
        if (draw) dashed.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next;
        draw = !draw;
      }
    }
    return dashed;
  }

  @override
  bool shouldRepaint(_HrRangePainter old) => old.buckets != buckets;
}

/// Tiny painter for the legend swatches (a short solid or dashed line
/// segment) so the HR chart's "Range"/"Mean" legend visually matches what
/// the chart itself draws, instead of a color dot that doesn't distinguish
/// a dashed band boundary from a solid mean line.
class _LegendLinePainter extends CustomPainter {
  final Color color;
  final bool dashed;
  final bool thin;

  _LegendLinePainter({required this.color, required this.dashed, required this.thin});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = dashed ? color.withOpacity(0.7) : color
      ..strokeWidth = thin ? 1.4 : 2.2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    const dash = 2.0, gap = 2.5;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset((x + dash).clamp(0, size.width), y), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_LegendLinePainter old) => old.color != color || old.dashed != dashed || old.thin != thin;
}

/// Miniature version of _HrRangePainter's gap hatch, for the "what does
/// this mean" info sheet — same diagonal-stripe pattern at swatch size so
/// it's recognizable as the same thing seen on the chart itself.
class _HatchSwatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)));
    canvas.drawRect(rect, Paint()..color = AppColors.cardBackground);
    final linePaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1.5;
    const spacing = 4.0;
    for (var x = -size.height; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), linePaint);
    }
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = AppColors.textSecondary.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75,
    );
  }

  @override
  bool shouldRepaint(_HatchSwatchPainter old) => false;
}
