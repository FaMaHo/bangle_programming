import 'package:flutter/material.dart';
import '../services/database_helper.dart';
import '../services/ble_service.dart';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final BleService _ble = BleService();
  Map<String, dynamic>? _dbStats;
  bool _isLoading = false;
  String _testResult = '';

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);
    try {
      final stats = await _db.getDatabaseStats();
      setState(() {
        _dbStats = stats;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _testResult = 'Error loading stats: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _testInsertData() async {
    setState(() {
      _isLoading = true;
      _testResult = 'Testing database insertion...';
    });

    try {
      // Insert 10 test readings
      final now = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < 10; i++) {
        await _db.insertHeartRateWithTimestamp(
          now + (i * 1000),
          70 + i,
          90 + i,
          'TEST_DEVICE',
        );
        await _db.insertAccelerometerWithTimestamp(
          now + (i * 1000),
          100 * i,
          200 * i,
          300 * i,
          'TEST_DEVICE',
        );
      }

      setState(() {
        _testResult = '✅ Successfully inserted 10 test readings!';
      });
      await _loadStats();
    } catch (e) {
      setState(() {
        _testResult = '❌ Error: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _clearDatabase() async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Database?'),
        content: const Text('This will delete ALL heart rate and accelerometer data.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      _isLoading = true;
      _testResult = 'Clearing database...';
    });

    try {
      final db = await _db.database;
      await db.delete('heart_rate');
      await db.delete('accelerometer');

      setState(() {
        _testResult = '✅ Database cleared successfully!';
      });
      await _loadStats();
    } catch (e) {
      setState(() {
        _testResult = '❌ Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug & Diagnostics'),
        backgroundColor: Colors.deepPurple,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStatsCard(),
                  const SizedBox(height: 16),
                  _buildConnectionCard(),
                  const SizedBox(height: 16),
                  _buildTestActionsCard(),
                  if (_testResult.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _buildResultCard(),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildStatsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Database Statistics',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadStats,
                ),
              ],
            ),
            const Divider(),
            if (_dbStats != null) ...[
              _buildStatRow('HR Readings', '${_dbStats!['total_hr_readings']}'),
              _buildStatRow('Accel Readings', '${_dbStats!['total_accel_readings']}'),
              _buildStatRow('First Reading', _dbStats!['first_reading'] ?? 'None'),
              _buildStatRow('Last Reading', _dbStats!['last_reading'] ?? 'None'),
              _buildStatRow('Duration', '${_dbStats!['duration_hours']?.toStringAsFixed(2) ?? 0} hours'),
            ] else
              const Text('No data yet'),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'BLE Connection Status',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            _buildStatRow('Connected', _ble.isConnected ? '✅ Yes' : '❌ No'),
            _buildStatRow('Device Type', _ble.currentDeviceType.toString()),
            if (_ble.connectedDevice != null)
              _buildStatRow('Device Name', _ble.connectedDevice!.platformName),
          ],
        ),
      ),
    );
  }

  Widget _buildTestActionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Test Actions',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _testInsertData,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Insert 10 Test Readings'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _clearDatabase,
              icon: const Icon(Icons.delete_forever),
              label: const Text('Clear All Database Data'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    return Card(
      color: _testResult.startsWith('✅')
          ? Colors.green.shade50
          : (_testResult.startsWith('❌') ? Colors.red.shade50 : Colors.blue.shade50),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text(
          _testResult,
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
