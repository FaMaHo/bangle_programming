import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../theme/app_theme.dart';
import '../services/pdf_report_service.dart';
import '../services/report_service.dart';

/// Full cardiac risk report, generated once from a full 48h session —
/// mirrors fromDaria/generate_report_html.py's HTML report.
class ReportScreen extends StatefulWidget {
  final FinalReport report;

  const ReportScreen({super.key, required this.report});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  List<FeatureRow>? _topFeatures;
  bool _isSharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final importances = await ReportService.loadImportances();
    if (mounted) {
      setState(() => _topFeatures = widget.report.topFeatures(importances));
    }
  }

  /// Builds a proper paginated PDF (see PdfReportService — a real document,
  /// not a screenshot) and hands it to the OS share sheet, so "Print" and
  /// "Save as PDF" actually work instead of cropping one tall image to a
  /// single page.
  Future<void> _shareReport() async {
    if (_isSharing || _topFeatures == null) return;
    setState(() => _isSharing = true);
    try {
      final bytes = await PdfReportService.build(widget.report, _topFeatures!);
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'heart_sclerosis_report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share the report: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
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

  String _formatDate(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} · $h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final color = _riskColor(report.riskLevel);
    final pct = (report.score * 100);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Heart Sclerosis Risk Report',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Share report',
            icon: _isSharing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.textSecondary),
                  )
                : const Icon(Icons.ios_share_rounded, color: AppColors.textPrimary),
            onPressed: _isSharing ? null : _shareReport,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'AI Bracelet System  ·  NUST Politehnica Bucharest',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            _buildDisclaimer(),
            const SizedBox(height: 16),
            _buildScoreSection(color, pct, report),
            const SizedBox(height: 16),
            _buildOverviewSection(report),
            const SizedBox(height: 16),
            _buildFeaturesSection(),
            const SizedBox(height: 16),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildDisclaimer() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withOpacity(0.08),
        border: Border.all(color: AppColors.warning.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        '⚠ This is a research prototype, not a medical device. This report is '
        'designed to support — not replace — clinical evaluation. A score '
        'above 30% should prompt a cardiologist referral. All analysis runs '
        'locally on your device. No data is sent anywhere.',
        style: TextStyle(color: AppColors.textPrimary, fontSize: 12.5, height: 1.5),
      ),
    );
  }

  Widget _buildScoreSection(Color color, double pct, FinalReport report) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        children: [
          Text(
            '${pct.toStringAsFixed(1)}%',
            style: TextStyle(color: color, fontSize: 56, fontWeight: FontWeight.w800, height: 1.0),
          ),
          const SizedBox(height: 6),
          const Text(
            'CARDIAC RISK SCORE',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
            child: Text(
              '${report.riskLevel} RISK',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 20),
          // Matches fromDaria's gauge-fill gradient (green fading into the
          // risk color) instead of a flat fill.
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                Container(height: 12, color: AppColors.background),
                FractionallySizedBox(
                  widthFactor: report.score.clamp(0.0, 1.0),
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [AppColors.primaryGreen, color]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('0% — Healthy', style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
              Text('50%', style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
              Text('100% — High Risk', style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border(left: BorderSide(color: color, width: 4)),
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
            ),
            child: Text(
              report.assessment,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13.5, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewSection(FinalReport report) {
    // Mirrors fromDaria's meta-grid fields exactly, except "File" — there's
    // no single source filename in the live app (a session is assembled
    // from many synced pw*.csv chunks, not one file) — "Generated" fills
    // that slot with the one piece of equivalent, meaningful information.
    final items = [
      ['Windows analysed', '${report.nWindows}'],
      ['Data rows', '${report.nRows}'],
      ['Session duration', '~${report.durationHours.toStringAsFixed(1)} hours'],
      ['Mean HR', '${report.meanHr.toStringAsFixed(0)} bpm'],
      ['Mean RMSSD', '${report.meanRmssd.toStringAsFixed(1)} ms'],
      ['Generated', _formatDate(report.computedAt)],
    ];

    // A fixed-aspect-ratio GridView forces every cell to the same height
    // regardless of content — the "Generated" cell's two-line date/time
    // value overflowed it. Building rows of two content-sized cells instead
    // lets each cell grow to fit whatever it actually needs to show.
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      final second = i + 1 < items.length ? items[i + 1] : null;
      rows.add(
        Padding(
          padding: EdgeInsets.only(bottom: i + 2 < items.length ? 12 : 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildOverviewCell(items[i])),
              const SizedBox(width: 12),
              Expanded(child: second != null ? _buildOverviewCell(second) : const SizedBox()),
            ],
          ),
        ),
      );
    }

    return _buildSectionCard(
      title: 'Session Overview',
      child: Column(children: rows),
    );
  }

  Widget _buildOverviewCell(List<String> item) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(item[0].toUpperCase(), style: const TextStyle(color: AppColors.textSecondary, fontSize: 10.5, letterSpacing: 0.3)),
          const SizedBox(height: 2),
          Text(item[1], style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildFeaturesSection() {
    if (_topFeatures == null) {
      return _buildSectionCard(
        title: 'Top Influential Features',
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(child: CircularProgressIndicator(color: AppColors.primaryGreen)),
        ),
      );
    }

    final maxImportance = _topFeatures!.map((f) => f.importance).fold(0.0, (a, b) => a > b ? a : b);

    return _buildSectionCard(
      title: 'Top Influential Features',
      child: Column(
        children: _topFeatures!.asMap().entries.map((entry) {
          final i = entry.key + 1;
          final f = entry.value;
          final barWidth = maxImportance > 0 ? (f.importance / maxImportance) : 0.0;
          // Matches fromDaria's zebra-striped table rows (tr:nth-child(even)).
          final isEven = entry.key % 2 == 1;
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isEven ? AppColors.background : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('$i.', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(f.label, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                    Text(
                      f.unit.isEmpty ? f.value.toStringAsFixed(3) : '${f.value.toStringAsFixed(3)} ${f.unit}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: barWidth,
                    minHeight: 6,
                    backgroundColor: AppColors.background,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primaryGreen),
                  ),
                ),
                if (f.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(f.description, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.4)),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFooter() {
    // Matches fromDaria/generate_report_html.py's footer structure and
    // author credits exactly. The accuracy/AUC figures are real values from
    // assets/models/eval_metrics.json (93.7% / 0.986) rather than Python's
    // own footer string, which hardcodes stale numbers (95.3% / 0.990) that
    // don't match its own eval_metrics.json — the figures here are the
    // correct ones for this trained model.
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'Generated by AI Bracelet for Early Detection of Heart Sclerosis  ·  '
        'Model: XGBoost (AUC 0.986, Accuracy 93.7%)  ·  '
        'Daria Gladkykh · FatemehSadat MahmoudzadehHosseini · Prof. Dr. Ing. Nicolae Goga',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.textSecondary, fontSize: 11, height: 1.6),
      ),
    );
  }

  Widget _buildSectionCard({required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
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
          // Matches fromDaria's section-header underline (`.section h2`'s
          // border-bottom), in the app's own accent color.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.primaryGreen.withOpacity(0.2), width: 2)),
            ),
            child: Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
