import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/server_service.dart';

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final ServerService _server = ServerService.instance;
  final TextEditingController _urlController = TextEditingController();

  bool _isConnected = false;
  bool _isTesting = false;
  bool _isUploading = false;
  String _statusMessage = '';
  DataStats? _dataStats;

  @override
  void initState() {
    super.initState();
    _loadServerUrl();
    _loadDataStats();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadServerUrl() async {
    final url = await _server.getServerUrl();
    if (url != null) {
      _urlController.text = url;
    }
  }

  Future<void> _loadDataStats() async {
    final stats = await _server.getDataStats();
    setState(() {
      _dataStats = stats;
    });
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _statusMessage = 'Testing connection...';
    });

    // Save URL first
    await _server.setServerUrl(_urlController.text);

    final connected = await _server.testConnection();

    setState(() {
      _isTesting = false;
      _isConnected = connected;
      _statusMessage = connected
          ? '✅ Connected to server'
          : '❌ Connection failed';
    });
  }

  Future<void> _uploadData() async {
    if (_urlController.text.isEmpty) {
      setState(() {
        _statusMessage = '❌ Please enter server URL';
      });
      return;
    }

    setState(() {
      _isUploading = true;
      _statusMessage = 'Uploading data...';
    });

    final result = await _server.uploadData();

    setState(() {
      _isUploading = false;
      _statusMessage = result.success
          ? '✅ ${result.message}'
          : '❌ ${result.message}';
    });

    // Refresh stats after upload
    await _loadDataStats();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Server Upload',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 24),

          // Data Statistics Card
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
                    Icon(Icons.analytics_outlined, color: AppColors.primaryGreen),
                    const SizedBox(width: 8),
                    const Text(
                      'Available Data',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_dataStats != null) ...[
                  _buildStatRow('Heart Rate Records', '${_dataStats!.heartRateRecords}'),
                  const SizedBox(height: 8),
                  _buildStatRow('Accelerometer Records', '${_dataStats!.accelerometerRecords}'),
                  const SizedBox(height: 8),
                  if (_dataStats!.firstReading != null)
                    _buildStatRow('First Reading', _formatDate(_dataStats!.firstReading!)),
                  if (_dataStats!.lastReading != null) ...[
                    const SizedBox(height: 8),
                    _buildStatRow('Last Reading', _formatDate(_dataStats!.lastReading!)),
                  ],
                ] else
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Server Configuration Card
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
                    Icon(Icons.cloud_outlined, color: AppColors.primaryGreen),
                    const SizedBox(width: 8),
                    const Text(
                      'Server Configuration',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'http://192.168.1.100:5000',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: const Icon(Icons.link),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isTesting ? null : _testConnection,
                        icon: _isTesting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_tethering),
                        label: Text(_isTesting ? 'Testing...' : 'Test Connection'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(color: AppColors.primaryGreen),
                          foregroundColor: AppColors.primaryGreen,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_isConnected)
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.primaryGreen.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_circle,
                          color: AppColors.primaryGreen,
                          size: 24,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Upload Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_isUploading || (_dataStats?.heartRateRecords ?? 0) == 0)
                  ? null
                  : _uploadData,
              icon: _isUploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_upload),
              label: Text(_isUploading ? 'Uploading...' : 'Upload Data to Server'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Status Message
          if (_statusMessage.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _statusMessage.startsWith('✅')
                    ? AppColors.primaryGreen.withOpacity(0.1)
                    : Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _statusMessage.startsWith('✅')
                      ? AppColors.primaryGreen
                      : Colors.orange,
                ),
              ),
              child: Text(
                _statusMessage,
                style: TextStyle(
                  color: _statusMessage.startsWith('✅')
                      ? AppColors.primaryGreen
                      : Colors.orange[900],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

          const Spacer(),

          // Info Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue[700]),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Data will be uploaded as CSV format for machine learning analysis',
                    style: TextStyle(
                      color: Colors.blue[900],
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
