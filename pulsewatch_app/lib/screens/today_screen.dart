import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';
import '../services/ble_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final BleService _bleService = BleService();

  int _minHR = 0;
  int _maxHR = 0;
  int _avgHR = 0;
  int _totalReadings = 0;
  bool _isConnected = false;
  int _liveRecordsReceived = 0;

  Timer? _statsTimer;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _transferSubscription;

  @override
  void initState() {
    super.initState();

    // Load initial stats
    _loadStats();

    // Refresh stats every 5 seconds
    _statsTimer = Timer.periodic(Duration(seconds: 5), (_) {
      _loadStats();
    });

    // Subscribe to connection status
    _connectionSubscription = _bleService.connectionStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isConnected = (state == BluetoothConnectionState.connected);
          if (!_isConnected) {
            _liveRecordsReceived = 0;
          }
        });
      }
    });

    // Subscribe to transfer progress (live data)
    _transferSubscription = _bleService.transferProgressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _liveRecordsReceived = progress.recordsReceived;
        });
      }
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
    _statsTimer?.cancel();
    _connectionSubscription?.cancel();
    _transferSubscription?.cancel();
    super.dispose();
  }

  int _calculateSignalScore() {
    if (_totalReadings == 0) return 0;
    if (_totalReadings < 100) return 50;
    if (_totalReadings < 500) return 70;
    return 85;
  }

  @override
  Widget build(BuildContext context) {
    final signalScore = _calculateSignalScore();
    final bool hasData = _totalReadings > 0;
    
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Today',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            _getFormattedDate(),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),

          // Live Connection Status
          if (_isConnected)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.primaryGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primaryGreen.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primaryGreen,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.watch,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Watch Connected',
                          style: TextStyle(
                            color: AppColors.primaryGreen,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'Live: $_liveRecordsReceived readings',
                          style: TextStyle(
                            color: AppColors.primaryGreen.withOpacity(0.8),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.radio_button_checked,
                    color: AppColors.primaryGreen,
                    size: 16,
                  ),
                ],
              ),
            ),

          // Signal Score Card
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
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Signal Score',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: hasData ? AppColors.primaryGreen.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        hasData ? 'Data Available' : 'No Data',
                        style: TextStyle(
                          color: hasData ? AppColors.primaryGreen : Colors.grey,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '$signalScore',
                  style: const TextStyle(
                    color: AppColors.primaryGreen,
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  signalScore >= 80 ? 'Good' : signalScore >= 50 ? 'Fair' : 'Low',
                  style: const TextStyle(
                    color: AppColors.primaryGreen,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$_totalReadings readings today',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Heart Rate Card
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
                  children: [
                    Icon(
                      Icons.favorite,
                      color: AppColors.secondaryCoral,
                      size: 32,
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Heart Rate',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          _avgHR > 0 ? '$_avgHR BPM' : '--',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_totalReadings > 0) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatColumn('Min', _minHR),
                      _buildStatColumn('Avg', _avgHR),
                      _buildStatColumn('Max', _maxHR),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatColumn(String label, int value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value > 0 ? '$value' : '--',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _getFormattedDate() {
    final now = DateTime.now();
    final months = ['January', 'February', 'March', 'April', 'May', 'June',
                   'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[now.month - 1]} ${now.day}, ${now.year}';
  }
}