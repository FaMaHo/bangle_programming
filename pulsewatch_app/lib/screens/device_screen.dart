import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../debug/debug_panel.dart';
import '../theme/app_theme.dart';
import '../services/ble_service.dart';
import '../services/database_helper.dart';
import '../services/sync_log_service.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  final BleService _bleService = BleService();
  List<ScanResult> _devices = [];
  bool _isScanning = false;
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;

  StreamSubscription<List<ScanResult>>? _devicesSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  int _totalReadings = 0;
  int _latestConfidence = 0;
  Timer? _statsTimer;

  // Diagnostics — see sync_log_service.dart. Surfaced here so a failure
  // (especially one that happened unattended in the background) can be
  // read directly in the app instead of needing `adb logcat`.
  List<SyncLogEntry> _recentSync = [];
  bool _diagnosticsExpanded = false;

  // Reading timeline — see DatabaseHelper.findGaps. Answers "is data
  // actually arriving right now" and "were there gaps like the ones found
  // in exported session CSVs" directly in the app, live, instead of only
  // being discoverable afterward by eyeballing a downloaded file.
  DateTime? _lastReadingTime;
  List<ReadingGap> _recentGaps = [];
  bool _gapsExpanded = false;
  static const _gapThreshold = Duration(minutes: 5);
  static const _gapLookback = Duration(hours: 6);

  @override
  void initState() {
    super.initState();

    _loadStats();
    _statsTimer = Timer.periodic(const Duration(seconds: 15), (_) => _loadStats());

    setState(() {
      _connectionState = _bleService.isConnected
          ? BluetoothConnectionState.connected
          : BluetoothConnectionState.disconnected;
    });

    _devicesSubscription = _bleService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });

    _connectionSubscription = _bleService.connectionStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _connectionState = state;
        });
      }
    });

  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _connectionSubscription?.cancel();
    _statsTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStats() async {
    final total = await DatabaseHelper.instance.getTotalReadings();
    final confidence = await DatabaseHelper.instance.getLatestConfidence();
    final syncLog = await SyncLogService.instance.recent(limit: 10);
    final lastReading = await DatabaseHelper.instance.getLastReadingTime();
    final gaps = await DatabaseHelper.instance.findGaps(
      threshold: _gapThreshold,
      since: DateTime.now().subtract(_gapLookback),
    );
    if (mounted) {
      setState(() {
        _totalReadings = total;
        _latestConfidence = confidence;
        _recentSync = syncLog;
        _lastReadingTime = lastReading;
        _recentGaps = gaps;
      });
    }
  }

  Future<void> _startScan() async {
    bool isOn = await _bleService.isBluetoothOn();
    if (!isOn) {
      await _bleService.turnOnBluetooth();
    }

    setState(() {
      _isScanning = true;
    });

    await _bleService.startScan();

    setState(() {
      _isScanning = false;
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    bool success = await _bleService.connectToDevice(device);

    if (mounted) {
      Navigator.of(context).pop();
    }

    // On failure, show the actual reason (e.g. "watch did not finish
    // connecting within 15s" vs "doesn't expose the expected Bluetooth
    // characteristics") instead of a one-size-fits-all message — connectToDevice
    // just logged exactly this via SyncLogService.
    String? failureReason;
    if (!success) {
      final failure = await SyncLogService.instance.lastFailure();
      failureReason = failure?.message;
    }
    await _loadStats(); // refresh the diagnostics list with the new entry

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? '✅ Connected!' : '❌ ${failureReason ?? "Connection failed"}',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Compact "last sync" status that expands into a short history of
  /// connect/sync attempts — both interactive and background — so a
  /// failure that happened while the app wasn't open is still visible
  /// afterward instead of only ever reaching an invisible console log.
  Widget _buildDiagnosticsCard() {
    final latest = _recentSync.isNotEmpty ? _recentSync.first : null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _diagnosticsExpanded = !_diagnosticsExpanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    latest == null
                        ? Icons.history_rounded
                        : (latest.success
                            ? Icons.check_circle_outline
                            : Icons.error_outline),
                    color: latest == null
                        ? AppColors.textSecondary
                        : (latest.success ? AppColors.primaryGreen : AppColors.error),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Sync diagnostics',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          latest == null
                              ? 'No sync attempts yet'
                              : '${latest.success ? "OK" : "Failed"} • '
                                  '${latest.source == SyncSource.background ? "Background" : "App"} • '
                                  '${_relativeTime(latest.timestamp)}',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _diagnosticsExpanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_diagnosticsExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _recentSync.isEmpty
                  ? const Text(
                      'Nothing logged yet — connect to your watch to start.',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _recentSync.length,
                        separatorBuilder: (_, _) => const Divider(height: 12),
                        itemBuilder: (context, index) {
                          final e = _recentSync[index];
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: e.success ? AppColors.primaryGreen : AppColors.error,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${e.stage} · ${e.source == SyncSource.background ? "Background" : "App"} · '
                                      '${_relativeTime(e.timestamp)}',
                                      style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      e.message,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  String _formatGapDuration(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    final hours = d.inMinutes ~/ 60;
    final mins = d.inMinutes % 60;
    return mins == 0 ? '${hours}h' : '${hours}h ${mins}m';
  }

  /// Live "is data actually arriving" view — the direct answer to "I'm not
  /// sure if there's a gap right now like the ones in the exported files."
  /// Pulls straight from the DB (DatabaseHelper.findGaps), so it reflects
  /// what's actually landed locally, independent of whatever the
  /// connection/notification state claims.
  Widget _buildGapsCard() {
    final ongoingGap = _lastReadingTime != null &&
        DateTime.now().difference(_lastReadingTime!) >= _gapThreshold;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _gapsExpanded = !_gapsExpanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    ongoingGap ? Icons.warning_amber_rounded : Icons.timeline_rounded,
                    color: ongoingGap ? AppColors.warning : AppColors.primaryGreen,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Last reading',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _lastReadingTime == null
                              ? 'No readings yet'
                              : '${_relativeTime(_lastReadingTime!)}'
                                  '${_recentGaps.isNotEmpty ? " • ${_recentGaps.length} gap${_recentGaps.length == 1 ? "" : "s"} in last 6h" : ""}',
                          style: TextStyle(
                            color: ongoingGap ? AppColors.warning : AppColors.textSecondary,
                            fontSize: 11,
                            fontWeight: ongoingGap ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _gapsExpanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_gapsExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _recentGaps.isEmpty
                  ? Text(
                      _lastReadingTime == null
                          ? 'No readings recorded yet.'
                          : 'No gaps of ${_gapThreshold.inMinutes}m+ in the last 6 hours.',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _recentGaps.length,
                        separatorBuilder: (_, _) => const Divider(height: 12),
                        itemBuilder: (context, index) {
                          final g = _recentGaps[index];
                          final isOngoing = index == 0 && ongoingGap;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isOngoing ? AppColors.warning : AppColors.error,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isOngoing
                                          ? 'Ongoing — started ${_relativeTime(g.start)}'
                                          : 'No data for ${_formatGapDuration(g.duration)}',
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${_relativeTime(g.start)} → ${isOngoing ? "now" : _relativeTime(g.end)}',
                                      style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _disconnect() async {
    await _bleService.disconnect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected')),
      );
    }
  }

  String _getDeviceTypeLabel() {
    switch (_bleService.currentDeviceType) {
      case DeviceType.bangleJS:
        return 'Bangle.js 2';
      case DeviceType.tWatch:
        return 'T-Watch S3 Plus';
      default:
        return _connectedDevice?.platformName ?? 'Unknown Device';
    }
  }

  IconData _getDeviceIcon() {
    switch (_bleService.currentDeviceType) {
      case DeviceType.bangleJS:
        return Icons.watch;
      case DeviceType.tWatch:
        return Icons.watch_outlined;
      default:
        return Icons.bluetooth;
    }
  }

  Color _getDeviceColor() {
    if (!isConnected) return AppColors.textSecondary;

    switch (_bleService.currentDeviceType) {
      case DeviceType.bangleJS:
        return AppColors.primaryGreen;
      case DeviceType.tWatch:
        return AppColors.secondaryCoral;
      default:
        return AppColors.primaryGreen;
    }
  }

  bool get isConnected =>
      _connectionState == BluetoothConnectionState.connected;

  /// Returns the filtered + sorted device list.
  /// Bangle.js devices appear first, then alphabetical.
  /// Computed once per build, not once per list item.
  List<ScanResult> get _sortedDevices {
    final filtered = _devices
        .where((d) => d.device.platformName.isNotEmpty)
        .toList();

    filtered.sort((a, b) {
      final aIsBangle =
          a.device.platformName.toLowerCase().contains('bangle');
      final bIsBangle =
          b.device.platformName.toLowerCase().contains('bangle');
      if (aIsBangle && !bIsBangle) return -1;
      if (!aIsBangle && bIsBangle) return 1;
      return a.device.platformName.compareTo(b.device.platformName);
    });

    return filtered;
  }


  // Real HRM confidence from the watch — not an arbitrary score derived
  // from how much data happens to have accumulated.
  Widget _buildSignalQualityCard() {
    final hasSignal = _latestConfidence > 0;
    final Color scoreColor = !hasSignal
        ? AppColors.textSecondary
        : _latestConfidence >= 80
            ? AppColors.primaryGreen
            : _latestConfidence >= 50
                ? AppColors.warning
                : AppColors.error;

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
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scoreColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.sensors_rounded, color: scoreColor, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Signal Quality',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  hasSignal ? 'From the watch\'s HRM sensor' : 'No data yet',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '$_totalReadings readings collected',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
          if (hasSignal)
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scoreColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$_latestConfidence%',
                  style: TextStyle(
                    color: scoreColor,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Compute once here — used by both itemCount and itemBuilder
    final sortedDevices = _sortedDevices;

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Device',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              if (kDebugMode)
                IconButton(
                  icon: const Icon(Icons.science_outlined, color: AppColors.textSecondary),
                  tooltip: 'Preview controls',
                  onPressed: () => DebugPanel.show(context),
                ),
            ],
          ),
          const SizedBox(height: 24),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
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
                Icon(
                  isConnected ? _getDeviceIcon() : Icons.watch_outlined,
                  size: 48,
                  color: _getDeviceColor(),
                ),
                const SizedBox(height: 16),
                Text(
                  isConnected ? 'Connected' : 'Not Connected',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isConnected
                      ? _getDeviceTypeLabel()
                      : 'Scan to find your watch',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 20),

                if (!isConnected) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isScanning ? null : _startScan,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        _isScanning ? 'Scanning...' : 'Scan for Devices',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.primaryGreen.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.primaryGreen.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            color: AppColors.primaryGreen, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Connected - Data streaming automatically',
                            style: TextStyle(
                              color: AppColors.primaryGreen,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _disconnect,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: const BorderSide(color: AppColors.error),
                      ),
                      child: const Text(
                        'Disconnect',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Signal Quality Card
          _buildSignalQualityCard(),
          const SizedBox(height: 16),

          // Reading timeline / gap detection — see DatabaseHelper.findGaps.
          _buildGapsCard(),
          const SizedBox(height: 16),

          // Sync diagnostics — see sync_log_service.dart.
          _buildDiagnosticsCard(),
          const SizedBox(height: 16),

          if (!isConnected && sortedDevices.isNotEmpty) ...[
            const Text(
              'Found Devices',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: sortedDevices.length,
                itemBuilder: (context, index) {
                  final device = sortedDevices[index];
                  final name = device.device.platformName;
                  final isBangle = name.toLowerCase().contains('bangle');
                  final isTWatch = name.toLowerCase().contains('t-watch') ||
                      name.toLowerCase().contains('twatch');
                  final isSupported = isBangle || isTWatch;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(12),
                      border: isSupported
                          ? Border.all(
                              color: isBangle
                                  ? AppColors.primaryGreen
                                  : AppColors.secondaryCoral,
                              width: 2,
                            )
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isSupported ? Icons.watch : Icons.bluetooth,
                          color: isSupported
                              ? (isBangle
                                  ? AppColors.primaryGreen
                                  : AppColors.secondaryCoral)
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: isSupported
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                ),
                              ),
                              Text(
                                device.device.remoteId.toString(),
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              if (isSupported) ...[
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: (isBangle
                                            ? AppColors.primaryGreen
                                            : AppColors.secondaryCoral)
                                        .withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    isBangle ? 'Bangle.js' : 'T-Watch',
                                    style: TextStyle(
                                      color: isBangle
                                          ? AppColors.primaryGreen
                                          : AppColors.secondaryCoral,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${device.rssi} dBm',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            ElevatedButton(
                              onPressed: () =>
                                  _connectToDevice(device.device),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isSupported
                                    ? (isBangle
                                        ? AppColors.primaryGreen
                                        : AppColors.secondaryCoral)
                                    : AppColors.textSecondary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                minimumSize: Size.zero,
                              ),
                              child: const Text('Connect'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  BluetoothDevice? get _connectedDevice => _bleService.connectedDevice;
}