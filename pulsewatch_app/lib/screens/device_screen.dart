import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../debug/debug_panel.dart';
import '../theme/app_theme.dart';
import '../services/ble_service.dart';
import '../services/database_helper.dart';
import '../services/sync_log_service.dart';
import '../widgets/app_bottom_sheet.dart';
import '../widgets/loading_state.dart';

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
  int _latestConfidence = 0;
  Timer? _statsTimer;

  // Reading timeline — see DatabaseHelper.findGaps. Answers "is data
  // actually arriving right now" and "were there gaps like the ones found
  // in exported session CSVs" directly in the app, live, instead of only
  // being discoverable afterward by eyeballing a downloaded file. Sync
  // diagnostics (raw connection/sync attempt logs) used to live on this
  // screen too, but that's developer-flavored detail a study participant
  // has no use for — it now lives in the debug panel (see debug_panel.dart)
  // instead of cluttering the patient-facing screen.
  DateTime? _lastReadingTime;
  List<ReadingGap> _recentGaps = [];
  static const _gapThreshold = Duration(minutes: 5);
  static const _gapLookback = Duration(hours: 6);

  // Only gates the signal/data card's first load — the connection status
  // card above it comes from BLE streams, not this DB query, so it stays
  // visible throughout. Never reset back to true afterward: the periodic
  // _statsTimer refreshes silently, same as Home.
  bool _loading = true;

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
    final confidence = await DatabaseHelper.instance.getLatestConfidence();
    final lastReading = await DatabaseHelper.instance.getLastReadingTime();
    final gaps = await DatabaseHelper.instance.findGaps(
      threshold: _gapThreshold,
      since: DateTime.now().subtract(_gapLookback),
    );
    if (mounted) {
      setState(() {
        _loading = false;
        _latestConfidence = confidence;
        _lastReadingTime = lastReading;
        _recentGaps = gaps;
      });
    }
  }

  // Scanning is what actually triggers the OS Bluetooth (and, on Android
  // <12 only, Location — capped out of the manifest for newer versions,
  // see AndroidManifest.xml) permission dialogs. Bluetooth is the one
  // reason that's true on every version, so it's the only one named here
  // rather than caveating an old-Android technicality most users will
  // never hit. Explained once, the first time, rather than letting the
  // bare system dialog be the first thing the user sees. Declining here
  // skips the scan entirely rather than firing the OS dialog anyway; a
  // second tap on "Scan for Devices" won't re-show this, matching the
  // app's other one-time rationale prompts.
  Future<void> _startScan() async {
    if (await _bleService.needsBleScanRationale()) {
      if (!mounted) return;
      final proceed = await showAppConfirmSheet(
        context: context,
        icon: Icons.bluetooth_searching_rounded,
        iconColor: AppColors.primaryGreen,
        title: 'Connect your watch',
        body: 'Bluetooth lets PulseWatch talk to your watch.',
        primaryLabel: 'Allow',
        secondaryLabel: 'Not now',
      );
      await _bleService.markBleScanRationaleShown();
      if (proceed != true) return;
    }

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

  String _formatGapDuration(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    final hours = d.inMinutes ~/ 60;
    final mins = d.inMinutes % 60;
    return mins == 0 ? '${hours}h' : '${hours}h ${mins}m';
  }

  Future<void> _disconnect() async {
    // A routine action (charging, adjusting the strap) — not destructive
    // like logout — so this is a plain double-check against an accidental
    // tap, not the heavier "are you sure" treatment. Disconnecting does
    // pause the study's data collection though, so it's worth confirming
    // rather than acting the instant the button is tapped.
    final confirmed = await showAppConfirmSheet(
      context: context,
      icon: Icons.bluetooth_disabled_rounded,
      iconColor: AppColors.warning,
      title: 'Disconnect watch?',
      body: "You'll stop collecting heart rate data until you reconnect — "
          "try to put the watch back on again soon so we don't miss too "
          'much of your session.',
      primaryLabel: 'Disconnect',
      secondaryLabel: 'Stay connected',
    );
    if (confirmed != true) return;

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


  // Plain-language read on the live HRM confidence, not a raw reading
  // count — a patient can act on "good contact" / "adjust the strap" in a
  // way a number like "295600 readings collected" never gave them.
  String _signalStatusText(bool hasSignal, Color scoreColor) {
    if (!hasSignal) return 'No signal yet';
    if (scoreColor == AppColors.primaryGreen) return 'Good contact';
    if (scoreColor == AppColors.warning) return 'Signal a bit weak';
    return 'Poor contact';
  }

  /// One combined "is the watch actually reading me well right now" card —
  /// live signal quality plus when data last arrived, with a gap called out
  /// only when one has actually happened recently. Replaces three separate
  /// debug-flavored cards (signal quality with a raw reading count, an
  /// expandable gap list, and raw sync logs) with the single answer a study
  /// participant actually needs; the full technical detail still exists in
  /// the debug panel for dev/QA use.
  Widget _buildSignalAndDataCard() {
    final hasSignal = _latestConfidence > 0;
    final Color scoreColor = !hasSignal
        ? AppColors.textSecondary
        : _latestConfidence >= 80
            ? AppColors.primaryGreen
            : _latestConfidence >= 50
                ? AppColors.warning
                : AppColors.error;

    final ongoingGap = _lastReadingTime != null &&
        DateTime.now().difference(_lastReadingTime!) >= _gapThreshold;

    return Column(
      children: [
        Container(
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
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scoreColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.sensors_rounded, color: scoreColor, size: 19),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _signalStatusText(hasSignal, scoreColor),
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Text(
                          'Signal quality from the sensor',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  if (hasSignal)
                    Text(
                      '$_latestConfidence%',
                      style: TextStyle(color: scoreColor, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 0.5),
              ),
              Row(
                children: [
                  const Icon(Icons.access_time_rounded, size: 15, color: AppColors.textSecondary),
                  const SizedBox(width: 10),
                  Text(
                    _lastReadingTime == null
                        ? 'No readings yet'
                        : 'Last reading ${_relativeTime(_lastReadingTime!)}',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_recentGaps.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
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
                const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_gapSummaryText(ongoingGap), style: const TextStyle(color: AppColors.textPrimary, fontSize: 12.5)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _gapSummaryText(bool ongoingGap) {
    final gap = _recentGaps.first;
    final extra = _recentGaps.length > 1 ? ' (+${_recentGaps.length - 1} more)' : '';
    if (ongoingGap) {
      return 'No new data for ${_formatGapDuration(DateTime.now().difference(gap.start))}$extra';
    }
    return 'One ${_formatGapDuration(gap.duration)} gap ${_relativeTime(gap.start)}$extra';
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

          // Live signal quality + last-reading/gap status.
          _loading
              ? const LoadingState(message: 'Checking your watch data…')
              : _buildSignalAndDataCard(),
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