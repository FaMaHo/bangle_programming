import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  final DatabaseHelper _db = DatabaseHelper.instance;
  
  Map<int, bool> _weekData = {}; // day index -> has data
  int _weekMinHR = 0;
  int _weekMaxHR = 0;
  int _weekAvgHR = 0;
  int _totalReadings = 0;
  int _weekAvgConfidence = 0;

  @override
  void initState() {
    super.initState();
    _loadWeeklyData();
  }

  Future<void> _loadWeeklyData() async {
    final now = DateTime.now();
    final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
    
    // Get data for each day of the week
    Map<int, bool> weekData = {};
    for (int i = 0; i < 7; i++) {
      final day = startOfWeek.add(Duration(days: i));
      final startOfDay = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
      final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59).millisecondsSinceEpoch;
      
      final db = await _db.database;
      final result = await db.rawQuery('''
        SELECT COUNT(*) as count FROM heart_rate 
        WHERE timestamp >= ? AND timestamp <= ?
      ''', [startOfDay, endOfDay]);
      
      final count = (result.first['count'] as int?) ?? 0;
      weekData[i] = count > 0;
    }
    
    // Get week stats (last 7 days)
    final sevenDaysAgo = now.subtract(Duration(days: 7)).millisecondsSinceEpoch;
    final db = await _db.database;
    final stats = await db.rawQuery('''
      SELECT
        MIN(bpm) as minHR,
        MAX(bpm) as maxHR,
        AVG(bpm) as avgHR,
        COUNT(*) as count
      FROM heart_rate
      WHERE timestamp >= ?
    ''', [sevenDaysAgo]);
    final avgConfidence = await _db.getAvgConfidence(sinceMillis: sevenDaysAgo);

    if (mounted) {
      setState(() {
        _weekData = weekData;
        _weekMinHR = (stats.first['minHR'] as num?)?.toInt() ?? 0;
        _weekMaxHR = (stats.first['maxHR'] as num?)?.toInt() ?? 0;
        _weekAvgHR = (stats.first['avgHR'] as num?)?.round() ?? 0;
        _totalReadings = (stats.first['count'] as int?) ?? 0;
        _weekAvgConfidence = avgConfidence;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = now.weekday - 1; // 0 = Monday
    
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Insights',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 24),

          // Weekly Summary Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
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
                      'This Week',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '$_totalReadings readings',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Days row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildDayIndicator('M', 0, today == 0, _weekData[0] ?? false),
                    _buildDayIndicator('T', 1, today == 1, _weekData[1] ?? false),
                    _buildDayIndicator('W', 2, today == 2, _weekData[2] ?? false),
                    _buildDayIndicator('T', 3, today == 3, _weekData[3] ?? false),
                    _buildDayIndicator('F', 4, today == 4, _weekData[4] ?? false),
                    _buildDayIndicator('S', 5, today == 5, _weekData[5] ?? false),
                    _buildDayIndicator('S', 6, today == 6, _weekData[6] ?? false),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Stats Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Average Heart Rate',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _weekAvgHR > 0 ? '$_weekAvgHR' : '--',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text(
                        'BPM',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildStatItem('Min', _weekMinHR),
                    const SizedBox(width: 24),
                    _buildStatItem('Max', _weekMaxHR),
                    if (_weekAvgConfidence > 0) ...[
                      const SizedBox(width: 24),
                      _buildStatItem('Signal', _weekAvgConfidence, suffix: '%'),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Days Recorded Card — how many of the last 7 days have any data,
          // rather than a guessed "expected sample count" that doesn't
          // match how often the watch actually reports.
          if (_totalReadings > 0)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.cardBackground,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Days Recorded',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _daysRecordedRatio(),
                    backgroundColor: AppColors.background,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryGreen),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_daysRecordedCount()} of 7 days this week',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDayIndicator(String day, int dayIndex, bool isToday, bool hasData) {
    return Column(
      children: [
        Text(
          day,
          style: TextStyle(
            color: isToday ? AppColors.primaryGreen : AppColors.textSecondary,
            fontSize: 12,
            fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: hasData 
                ? (isToday ? AppColors.primaryGreen : AppColors.primaryGreen.withOpacity(0.7))
                : AppColors.background,
            shape: BoxShape.circle,
            border: isToday && !hasData
                ? Border.all(color: AppColors.primaryGreen, width: 2)
                : null,
          ),
          child: hasData
              ? const Icon(Icons.check, color: Colors.white, size: 16)
              : null,
        ),
      ],
    );
  }

  Widget _buildStatItem(String label, int value, {String suffix = ' BPM'}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
        Text(
          value > 0 ? '$value$suffix' : '--$suffix',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  int _daysRecordedCount() => _weekData.values.where((hasData) => hasData).length;

  double _daysRecordedRatio() => _daysRecordedCount() / 7;
}