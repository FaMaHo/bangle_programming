import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
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
          'Cardiac Risk Report',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
        'above 25% should prompt a cardiologist referral. All analysis runs '
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
            'Cardiac Risk Score',
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
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: (report.score).clamp(0.0, 1.0),
              minHeight: 12,
              backgroundColor: AppColors.background,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('0% — Healthy', style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
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
    final items = [
      ['Windows analysed', '${report.nWindows}'],
      ['Data points', '${report.nRows}'],
      ['Session duration', '~${report.durationHours.toStringAsFixed(1)} hours'],
      ['Mean HR', '${report.meanHr.toStringAsFixed(0)} bpm'],
      ['Mean RMSSD', '${report.meanRmssd.toStringAsFixed(1)} ms'],
      ['Generated', _formatDate(report.computedAt)],
    ];

    return _buildSectionCard(
      title: 'Session Overview',
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.6,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        children: items.map((item) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(item[0], style: const TextStyle(color: AppColors.textSecondary, fontSize: 10.5, letterSpacing: 0.3)),
                const SizedBox(height: 2),
                Text(item[1], style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w700)),
              ],
            ),
          );
        }).toList(),
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
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
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
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'Model: XGBoost · Accuracy 93.7% · AUC-ROC 0.986\n'
        'AI Bracelet for Early Detection of Heart Sclerosis',
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
          Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
