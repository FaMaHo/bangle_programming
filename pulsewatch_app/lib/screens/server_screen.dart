import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
  DataStats? _dataStats;
  DateTime? _lastUploadTime;
  String _displayName = '';
  String _patientId = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final url = await _server.getServerUrl();
    final name = await _server.getDisplayName();
    final id = await _server.getPatientId();
    final stats = await _server.getDataStats();
    final lastUpload = await _server.getLastUploadTime();

    if (mounted) {
      setState(() {
        if (url != null) _urlController.text = url;
        _displayName = name;
        _patientId = id;
        _dataStats = stats;
        _lastUploadTime = lastUpload;
      });
      if (url != null && url.isNotEmpty) {
        _silentConnectionTest(url);
      }
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _isConnected = false;
    });
    await _server.setServerUrl(_urlController.text.trim());
    final ok = await _server.testConnection();
    if (mounted) {
      setState(() {
        _isTesting = false;
        _isConnected = ok;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '✅ Connected to server' : '❌ Could not connect'),
          backgroundColor: ok ? AppColors.primaryGreen : AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  // Silently re-checks connection on screen init — no snackbar, no spinner.
  Future<void> _silentConnectionTest(String url) async {
    final ok = await _server.testConnection();
    if (mounted) setState(() => _isConnected = ok);
  }

  // ─── QR Scanner ───────────────────────────────────────────────────────────

  void _openQRScanner() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _QRScannerScreen(
        onScanned: (url) async {
          _urlController.text = url;
          await _server.setServerUrl(url);
          setState(() => _isConnected = false);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('✅ Server URL set from QR code'),
                backgroundColor: AppColors.primaryGreen,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            );
            await _testConnection();
          }
        },
      )),
    );
  }

  // ─── Consent bottom sheet ─────────────────────────────────────────────────

  void _showExportSheet() {
    if (_urlController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter or scan the server URL first'),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ConsentSheet(
        displayName: _displayName,
        patientId: _patientId,
        recordCount: _dataStats?.heartRateRecords ?? 0,
        onConfirmed: _doUpload,
      ),
    );
  }

  Future<void> _doUpload() async {
    await _server.setServerUrl(_urlController.text.trim());

    final result = await _server.uploadData();

    if (!mounted) return;

    final stats = await _server.getDataStats();
    final lastUpload = await _server.getLastUploadTime();
    if (mounted) setState(() {
      _dataStats = stats;
      _lastUploadTime = lastUpload;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        backgroundColor:
            result.success ? AppColors.primaryGreen : AppColors.error,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasData = (_dataStats?.heartRateRecords ?? 0) > 0;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Upload Data',
              style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 6),
          Text(
            'Send your last 48 hours to the research team',
            style: Theme.of(context).textTheme.bodyMedium,
          ),

          const SizedBox(height: 24),

          _ProfileCard(displayName: _displayName, patientId: _patientId),
          const SizedBox(height: 16),
          _DataCard(stats: _dataStats, lastUploadTime: _lastUploadTime),
          const SizedBox(height: 16),

          // Server card — now with QR scan button
          _ServerCard(
            urlController: _urlController,
            isTesting: _isTesting,
            isConnected: _isConnected,
            onTest: _testConnection,
            onScanQR: _openQRScanner,
          ),

          const Spacer(),

          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: hasData ? _showExportSheet : null,
              icon: const Icon(Icons.cloud_upload_rounded, size: 20),
              label: const Text(
                'Export & Upload',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade200,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),

          if (!hasData)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Center(
                child: Text(
                  'No data recorded in the last 48 hours yet',
                  style: TextStyle(
                    color: AppColors.textSecondary.withOpacity(0.7),
                    fontSize: 12,
                  ),
                ),
              ),
            ),

          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ─── QR Scanner Screen ────────────────────────────────────────────────────────

class _QRScannerScreen extends StatefulWidget {
  final void Function(String url) onScanned;

  const _QRScannerScreen({required this.onScanned});

  @override
  State<_QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<_QRScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null) return;

    final value = barcode.rawValue ?? '';
    // Only accept if it looks like an HTTP URL
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That QR code does not contain a server URL'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    _scanned = true;
    _controller.stop();
    widget.onScanned(value);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Scan server QR code',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          // Camera feed
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),

          // Overlay with cut-out hint
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: AppColors.primaryGreen,
                      width: 2.5,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Point at the QR code on the researcher\'s screen',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _ProfileCard extends StatelessWidget {
  final String displayName;
  final String patientId;

  const _ProfileCard({required this.displayName, required this.patientId});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primaryGreen.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.person_rounded,
                color: AppColors.primaryGreen, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName.isEmpty ? 'Participant' : displayName,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.shield_rounded,
                        color: AppColors.primaryGreen, size: 12),
                    const SizedBox(width: 4),
                    Text(
                      'Research ID: $patientId',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DataCard extends StatelessWidget {
  final DataStats? stats;
  final DateTime? lastUploadTime;

  const _DataCard({this.stats, this.lastUploadTime});

  String _lastUploadLabel() {
    if (lastUploadTime == null) return 'Never uploaded';
    final diff = DateTime.now().difference(lastUploadTime!);
    if (diff.inMinutes < 1) return 'Uploaded just now';
    if (diff.inHours < 1) return 'Uploaded ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Uploaded ${diff.inHours}h ago';
    return 'Uploaded ${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final count = stats?.heartRateRecords ?? 0;
    final hasData = count > 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: hasData
                  ? AppColors.secondaryCoral.withOpacity(0.12)
                  : Colors.grey.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.favorite_rounded,
                color: hasData ? AppColors.secondaryCoral : Colors.grey,
                size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasData ? '$count readings ready' : 'No data yet',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  hasData
                      ? 'From the last 48 hours · anonymized before upload'
                      : 'Connect your watch and start recording',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      lastUploadTime != null
                          ? Icons.cloud_done_rounded
                          : Icons.cloud_off_rounded,
                      size: 11,
                      color: lastUploadTime != null
                          ? AppColors.primaryGreen
                          : AppColors.textSecondary.withOpacity(0.5),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _lastUploadLabel(),
                      style: TextStyle(
                        color: lastUploadTime != null
                            ? AppColors.primaryGreen
                            : AppColors.textSecondary.withOpacity(0.5),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  final TextEditingController urlController;
  final bool isTesting;
  final bool isConnected;
  final VoidCallback onTest;
  final VoidCallback onScanQR;

  const _ServerCard({
    required this.urlController,
    required this.isTesting,
    required this.isConnected,
    required this.onTest,
    required this.onScanQR,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Research server',
            style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // URL text field
              Expanded(
                child: TextField(
                  controller: urlController,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'http://192.168.1.100:5001',
                    hintStyle: TextStyle(
                        color: AppColors.textSecondary.withOpacity(0.5),
                        fontSize: 13),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: Colors.grey.withOpacity(0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: Colors.grey.withOpacity(0.2)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                          color: AppColors.primaryGreen, width: 1.5),
                    ),
                  ),
                  keyboardType: TextInputType.url,
                ),
              ),
              const SizedBox(width: 8),

              // QR scan button
              GestureDetector(
                onTap: onScanQR,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.primaryGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.primaryGreen.withOpacity(0.4)),
                  ),
                  child: const Icon(Icons.qr_code_scanner_rounded,
                      color: AppColors.primaryGreen, size: 18),
                ),
              ),
              const SizedBox(width: 8),

              // Test connection button
              GestureDetector(
                onTap: isTesting ? null : onTest,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: isConnected
                        ? AppColors.primaryGreen.withOpacity(0.12)
                        : AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isConnected
                          ? AppColors.primaryGreen
                          : Colors.grey.withOpacity(0.3),
                    ),
                  ),
                  child: isTesting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primaryGreen),
                        )
                      : Icon(
                          isConnected
                              ? Icons.check_rounded
                              : Icons.wifi_tethering_rounded,
                          color: isConnected
                              ? AppColors.primaryGreen
                              : AppColors.textSecondary,
                          size: 18,
                        ),
                ),
              ),
            ],
          ),
          if (isConnected) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.circle, color: AppColors.primaryGreen, size: 8),
                const SizedBox(width: 6),
                const Text('Connected',
                    style: TextStyle(
                        color: AppColors.primaryGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Consent bottom sheet ─────────────────────────────────────────────────────

class _ConsentSheet extends StatefulWidget {
  final String displayName;
  final String patientId;
  final int recordCount;
  final Future<void> Function() onConfirmed;

  const _ConsentSheet({
    required this.displayName,
    required this.patientId,
    required this.recordCount,
    required this.onConfirmed,
  });

  @override
  State<_ConsentSheet> createState() => _ConsentSheetState();
}

class _ConsentSheetState extends State<_ConsentSheet> {
  bool _consented = false;
  bool _isUploading = false;

  Future<void> _upload() async {
    setState(() => _isUploading = true);
    Navigator.of(context).pop();
    await widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Before you upload',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3)),
          const SizedBox(height: 6),
          const Text('Please read this — it only takes 10 seconds.',
              style:
                  TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          const SizedBox(height: 24),
          _InfoRow(
            icon: Icons.cloud_upload_outlined,
            iconColor: AppColors.primaryGreen,
            title: 'What is being sent',
            body:
                '${widget.recordCount} heart rate + movement readings from the last 48 hours.',
          ),
          const SizedBox(height: 16),
          _InfoRow(
            icon: Icons.person_off_outlined,
            iconColor: AppColors.primaryGreen,
            title: 'Your name is NOT included',
            body:
                'Only your anonymous research ID (${widget.patientId}) is attached to the data.',
          ),
          const SizedBox(height: 16),
          _InfoRow(
            icon: Icons.devices_other_outlined,
            iconColor: AppColors.primaryGreen,
            title: 'Device ID is NOT included',
            body:
                'No information that could identify your phone or watch is sent.',
          ),
          const SizedBox(height: 28),
          GestureDetector(
            onTap: () => setState(() => _consented = !_consented),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _consented
                    ? AppColors.primaryGreen.withOpacity(0.08)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _consented
                      ? AppColors.primaryGreen
                      : Colors.grey.withOpacity(0.25),
                  width: _consented ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: _consented
                          ? AppColors.primaryGreen
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: _consented
                            ? AppColors.primaryGreen
                            : Colors.grey.withOpacity(0.4),
                        width: 1.5,
                      ),
                    ),
                    child: _consented
                        ? const Icon(Icons.check_rounded,
                            color: Colors.white, size: 16)
                        : null,
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'I understand this is anonymized data shared voluntarily for cardiovascular research.',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: (_consented && !_isUploading) ? _upload : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryGreen,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade200,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: _isUploading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white))
                  : Text(
                      _consented
                          ? 'Upload ${widget.recordCount} readings'
                          : 'Please confirm above to continue',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;

  const _InfoRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(body,
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }
}