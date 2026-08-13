import 'package:flutter/material.dart';
import '../services/report_service.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_state.dart';
import 'report_screen.dart';

/// Every report a user has saved via Home's "Save report & start new
/// session" action — see DatabaseHelper's `reports` table and
/// ReportService.getReportHistory. Reached from Settings.
class ReportHistoryScreen extends StatefulWidget {
  const ReportHistoryScreen({super.key});

  @override
  State<ReportHistoryScreen> createState() => _ReportHistoryScreenState();
}

class _ReportHistoryScreenState extends State<ReportHistoryScreen> {
  bool _loading = true;
  List<FinalReport> _reports = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final reports = await ReportService.getReportHistory();
    if (mounted) {
      setState(() {
        _loading = false;
        _reports = reports;
      });
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

  String _formatDate(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} · $h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Your reports'),
        backgroundColor: AppColors.background,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
      ),
      body: _loading
          ? const LoadingState(message: 'Loading your saved reports…')
          : _reports.isEmpty
              ? _buildEmptyState()
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: _reports.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => _buildReportRow(_reports[i]),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.archive_outlined, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text(
              'No saved reports yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Once you complete a 48-hour session, use "Save report & start new '
              'session" on Home to keep it here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportRow(FinalReport report) {
    final color = _riskColor(report.riskLevel);
    final pct = (report.score * 100).round();

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReportScreen(report: report)),
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: color.withOpacity(0.12), shape: BoxShape.circle),
              child: Center(
                child: Text(
                  '$pct%',
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _riskLabel(report.riskLevel),
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatDate(report.computedAt),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
