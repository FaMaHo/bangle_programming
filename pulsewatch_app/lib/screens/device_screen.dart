import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../theme/app_theme.dart';
import '../services/ble_service.dart';

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
  TransferProgress? _transferProgress;
  
  StreamSubscription<List<ScanResult>>? _devicesSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<TransferProgress>? _transferSubscription;

  @override
  void initState() {
    super.initState();
    
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

    _transferSubscription = _bleService.transferProgressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _transferProgress = progress;
        });
      }
    });
  }
  
  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _connectionSubscription?.cancel();
    _transferSubscription?.cancel();
    super.dispose();
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

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '✅ Connected!' : '❌ Connection failed'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    await _bleService.disconnect();
    if (mounted) {
      setState(() {
        _transferProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected')),
      );
    }
  }

  Future<void> _syncData() async {
    if (_bleService.isTransferring) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync already in progress')),
      );
      return;
    }

    await _bleService.syncDataFromWatch();
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

  bool get isConnected => _connectionState == BluetoothConnectionState.connected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(
            'Device',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 24),

          // Connection Status Card
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
                // Icon
                Icon(
                  isConnected ? _getDeviceIcon() : Icons.watch_outlined,
                  size: 48,
                  color: _getDeviceColor(),
                ),
                const SizedBox(height: 16),
                
                // Status Text
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
                
                // Device Type Badge (when connected)
                if (isConnected && _bleService.currentDeviceType != DeviceType.unknown) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _getDeviceColor().withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _getDeviceColor(), width: 1),
                    ),
                    child: Text(
                      _bleService.currentDeviceType == DeviceType.tWatch 
                          ? '📡 Live Streaming' 
                          : '📁 File Transfer',
                      style: TextStyle(
                        color: _getDeviceColor(),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                
                const SizedBox(height: 20),

                // Transfer Progress
                if (_transferProgress != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _bleService.currentDeviceType == DeviceType.tWatch 
                                  ? 'Monitoring...' 
                                  : 'Syncing...',
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${_transferProgress!.recordsReceived} records',
                              style: TextStyle(
                                color: _getDeviceColor(),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _bleService.isTransferring ? null : 1.0,
                          backgroundColor: Colors.grey[200],
                          valueColor: AlwaysStoppedAnimation<Color>(_getDeviceColor()),
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _transferProgress!.status,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Action Buttons
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
                  // Sync Button (only show for Bangle.js)
                  if (_bleService.currentDeviceType == DeviceType.bangleJS) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _bleService.isTransferring ? null : _syncData,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_bleService.isTransferring 
                                ? Icons.sync 
                                : Icons.sync_outlined),
                            const SizedBox(width: 8),
                            Text(
                              _bleService.isTransferring ? 'Syncing...' : 'Sync Data from Watch',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  
                  // Info message for T-Watch
                  if (_bleService.currentDeviceType == DeviceType.tWatch) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.secondaryCoral.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.secondaryCoral.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, color: AppColors.secondaryCoral, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'T-Watch streams data automatically',
                              style: TextStyle(
                                color: AppColors.secondaryCoral,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  
                  // Disconnect Button
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

          // Found Devices List
          if (!isConnected && _devices.isNotEmpty) ...[
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
                itemCount: _devices.where((d) => 
                  d.device.platformName.isNotEmpty
                ).length,
                itemBuilder: (context, index) {
                  final filteredDevices = _devices
                      .where((d) => d.device.platformName.isNotEmpty)
                      .toList();
                  final device = filteredDevices[index];
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
                              color: isBangle ? AppColors.primaryGreen : AppColors.secondaryCoral, 
                              width: 2
                            )
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isSupported ? Icons.watch : Icons.bluetooth,
                          color: isSupported 
                              ? (isBangle ? AppColors.primaryGreen : AppColors.secondaryCoral)
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
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: (isBangle ? AppColors.primaryGreen : AppColors.secondaryCoral).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    isBangle ? 'Bangle.js' : 'T-Watch',
                                    style: TextStyle(
                                      color: isBangle ? AppColors.primaryGreen : AppColors.secondaryCoral,
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
                              onPressed: () => _connectToDevice(device.device),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isSupported 
                                    ? (isBangle ? AppColors.primaryGreen : AppColors.secondaryCoral)
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