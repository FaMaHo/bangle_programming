import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'database_helper.dart';

// Enum to identify device type
enum DeviceType {
  unknown,
  bangleJS,
  tWatch,
}

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  final DatabaseHelper _db = DatabaseHelper.instance;

  // DEVICE TYPE DETECTION
  DeviceType _currentDeviceType = DeviceType.unknown;
  DeviceType get currentDeviceType => _currentDeviceType;

  // Bangle.js - Nordic UART Service UUIDs
  static const String BANGLE_UART_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String BANGLE_UART_TX_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; // Write to watch
  static const String BANGLE_UART_RX_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"; // Receive from watch

  // T-Watch - Custom Service UUIDs
  static const String TWATCH_SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String TWATCH_ACCEL_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  static const String TWATCH_HR_UUID = "8ec414d4-2866-4126-b333-65977935047b";

  // Stream controllers
  final _devicesController = StreamController<List<ScanResult>>.broadcast();
  final _connectionStateController = StreamController<BluetoothConnectionState>.broadcast();
  final _transferProgressController = StreamController<TransferProgress>.broadcast();

  // Streams
  Stream<List<ScanResult>> get devicesStream => _devicesController.stream;
  Stream<BluetoothConnectionState> get connectionStateStream => _connectionStateController.stream;
  Stream<TransferProgress> get transferProgressStream => _transferProgressController.stream;

  // State
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  BluetoothDevice? _connectedDevice;
  
  // Bangle.js characteristics
  BluetoothCharacteristic? _bangleUartTxCharacteristic;
  BluetoothCharacteristic? _bangleUartRxCharacteristic;
  
  // T-Watch characteristics
  BluetoothCharacteristic? _tWatchAccelCharacteristic;
  BluetoothCharacteristic? _tWatchHRCharacteristic;
  
  String _receiveBuffer = '';
  bool _isTransferring = false;
  int _totalRecords = 0;
  List<String> _fileList = [];
  int _currentFileIndex = 0;

  bool get isScanning => _isScanning;
  bool get isConnected => _connectedDevice != null;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  bool get isTransferring => _isTransferring;

  // DEVICE TYPE DETECTION
  DeviceType _detectDeviceType(String deviceName) {
    deviceName = deviceName.toLowerCase();
    
    if (deviceName.contains('bangle')) {
      return DeviceType.bangleJS;
    } else if (deviceName.contains('t-watch') || deviceName.contains('twatch')) {
      return DeviceType.tWatch;
    }
    
    return DeviceType.unknown;
  }

  // SCANNING
  Future<void> startScan() async {
    if (_isScanning) return;

    _scanResults = [];
    _isScanning = true;

    FlutterBluePlus.scanResults.listen((results) {
      _scanResults = results;
      _devicesController.add(_scanResults);
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    _isScanning = false;
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _isScanning = false;
  }

  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  Future<void> turnOnBluetooth() async {
    await FlutterBluePlus.turnOn();
  }

  // CONNECTION
  Future<bool> connectToDevice(BluetoothDevice device) async {
    try {
      // Detect device type
      _currentDeviceType = _detectDeviceType(device.platformName);
      print("🔍 Detected device type: $_currentDeviceType");

      device.connectionState.listen((state) {
        _connectionStateController.add(state);
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevice = null;
          _bangleUartTxCharacteristic = null;
          _bangleUartRxCharacteristic = null;
          _tWatchAccelCharacteristic = null;
          _tWatchHRCharacteristic = null;
          _currentDeviceType = DeviceType.unknown;
        }
      });

      await device.connect(timeout: const Duration(seconds: 15));
      _connectedDevice = device;

      List<BluetoothService> services = await device.discoverServices();

      // Try to find characteristics based on device type
      bool success = false;
      
      if (_currentDeviceType == DeviceType.bangleJS) {
        success = await _setupBangleJS(services);
      } else if (_currentDeviceType == DeviceType.tWatch) {
        success = await _setupTWatch(services);
      } else {
        // Unknown device - try both
        success = await _setupBangleJS(services) || await _setupTWatch(services);
      }

      if (!success) {
        print("❌ Compatible characteristics not found");
        await device.disconnect();
        return false;
      }

      print("✅ Connected successfully to $_currentDeviceType!");

      // Auto-start recording on Bangle.js
      if (_currentDeviceType == DeviceType.bangleJS) {
        await _autoStartRecording();
      }

      return true;
      
    } catch (e) {
      print("Connection error: $e");
      return false;
    }
  }

  // Setup for Bangle.js (Nordic UART)
  Future<bool> _setupBangleJS(List<BluetoothService> services) async {
    for (BluetoothService service in services) {
      String serviceUuid = service.uuid.toString().toLowerCase();
      
      if (serviceUuid.contains(BANGLE_UART_SERVICE_UUID.toLowerCase())) {
        print("✅ Found Bangle.js UART Service");
        
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          String charUuid = characteristic.uuid.toString().toLowerCase();
          
          if (charUuid.contains(BANGLE_UART_TX_UUID.toLowerCase())) {
            _bangleUartTxCharacteristic = characteristic;
            print("✅ Bangle TX characteristic ready");
          }
          
          if (charUuid.contains(BANGLE_UART_RX_UUID.toLowerCase())) {
            _bangleUartRxCharacteristic = characteristic;
            print("✅ Bangle RX characteristic ready");
          }
        }
        
        if (_bangleUartRxCharacteristic != null && _bangleUartTxCharacteristic != null) {
          await _subscribeToUARTBangle();
          _currentDeviceType = DeviceType.bangleJS;
          return true;
        }
      }
    }
    return false;
  }

  // Setup for T-Watch (Custom Service)
  Future<bool> _setupTWatch(List<BluetoothService> services) async {
    for (BluetoothService service in services) {
      String serviceUuid = service.uuid.toString().toLowerCase();
      
      if (serviceUuid.contains(TWATCH_SERVICE_UUID.toLowerCase())) {
        print("✅ Found T-Watch Service");
        
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          String charUuid = characteristic.uuid.toString().toLowerCase();
          
          if (charUuid.contains(TWATCH_ACCEL_UUID.toLowerCase())) {
            _tWatchAccelCharacteristic = characteristic;
            print("✅ T-Watch Accel characteristic ready");
          }
          
          if (charUuid.contains(TWATCH_HR_UUID.toLowerCase())) {
            _tWatchHRCharacteristic = characteristic;
            print("✅ T-Watch HR characteristic ready");
          }
        }
        
        if (_tWatchAccelCharacteristic != null && _tWatchHRCharacteristic != null) {
          await _subscribeToTWatch();
          _currentDeviceType = DeviceType.tWatch;
          return true;
        }
      }
    }
    return false;
  }

  // BANGLE.JS UART SUBSCRIPTION
  Future<void> _subscribeToUARTBangle() async {
    if (_bangleUartRxCharacteristic != null) {
      await _bangleUartRxCharacteristic!.setNotifyValue(true);
      _bangleUartRxCharacteristic!.lastValueStream.listen((value) async {
        if (value.isEmpty) return;
        String chunk = utf8.decode(value);

        List<String> lines = chunk.split('\n');
        for (String line in lines) {
          line = line.trim();
          if (line.isEmpty) continue;

          // 🔍 Try to parse as live CSV data (6 comma-separated integers)
          List<String> parts = line.split(',');
          if (parts.length == 6) {
            try {
              // Parse all 6 fields
              int timestamp = int.parse(parts[0]);
              int bpm = int.parse(parts[1]);
              int confidence = int.parse(parts[2]);
              int x = int.parse(parts[3]);
              int y = int.parse(parts[4]);
              int z = int.parse(parts[5]);

              // ✅ LIVE DATA — save to DB immediately
              String? deviceId = _connectedDevice?.remoteId.toString();
              await _db.insertHeartRateWithTimestamp(timestamp, bpm, confidence, deviceId);
              await _db.insertAccelerometerWithTimestamp(timestamp, x, y, z, deviceId);

              // Update live count (only if NOT in file-sync mode)
              if (!_isTransferring) {
                _totalRecords++;
                _transferProgressController.add(TransferProgress(
                  currentFile: 0,
                  totalFiles: 0,
                  recordsReceived: _totalRecords,
                  status: 'Live HR: $bpm BPM • $_totalRecords readings',
                ));
              }
              continue; // Skip buffering
            } catch (e) {
              // Not valid live data — might be file content or command echo
            }
          }

          // If not live data, append to buffer (for file sync)
          _receiveBuffer += line + '\n';
        }
      });
    }
  }

  // T-WATCH SUBSCRIPTION (Real-time streaming)
  Future<void> _subscribeToTWatch() async {
    String? deviceId = _connectedDevice?.remoteId.toString();
    
    // Subscribe to accelerometer data
    if (_tWatchAccelCharacteristic != null) {
      await _tWatchAccelCharacteristic!.setNotifyValue(true);
      
      _tWatchAccelCharacteristic!.lastValueStream.listen((value) async {
        if (value.isNotEmpty) {
          String data = utf8.decode(value);
          // Format: "x,y,z"
          List<String> parts = data.split(',');
          if (parts.length == 3) {
            try {
              int x = int.parse(parts[0].trim());
              int y = int.parse(parts[1].trim());
              int z = int.parse(parts[2].trim());
              
              // Save to database with current timestamp
              await _db.insertAccelerometer(x, y, z, deviceId);
            } catch (e) {
              print("Error parsing accel data: $e");
            }
          }
        }
      });
    }
    
    // Subscribe to heart rate data
    if (_tWatchHRCharacteristic != null) {
      await _tWatchHRCharacteristic!.setNotifyValue(true);
      
      _tWatchHRCharacteristic!.lastValueStream.listen((value) async {
        if (value.isNotEmpty) {
          String data = utf8.decode(value);
          // Format: "70" (just BPM)
          try {
            int bpm = int.parse(data.trim());
            
            // Save to database with current timestamp
            await _db.insertHeartRate(bpm, deviceId);
            _totalRecords++;
            
            // Update progress occasionally
            if (_totalRecords % 10 == 0) {
              _transferProgressController.add(TransferProgress(
                currentFile: 0,
                totalFiles: 0,
                recordsReceived: _totalRecords,
                status: 'Real-time monitoring: $_totalRecords readings',
              ));
            }
          } catch (e) {
            print("Error parsing HR data: $e");
          }
        }
      });
    }
    
    print("✅ T-Watch real-time streaming started");
  }

  // BANGLE.JS - SEND COMMAND VIA UART
  Future<void> _sendCommandBangle(String command) async {
    if (_bangleUartTxCharacteristic == null) return;

    try {
      List<int> bytes = utf8.encode(command + '\n');
      await _bangleUartTxCharacteristic!.write(bytes, withoutResponse: false);
      print("📤 Sent to Bangle: $command");
    } catch (e) {
      print("Error sending command: $e");
    }
  }

  // AUTO-START RECORDING ON CONNECTION
  Future<void> _autoStartRecording() async {
    try {
      // Wait a moment for watch to be fully ready
      await Future.delayed(Duration(milliseconds: 500));

      // Send command to start recording
      // This calls the pulsewatch library's start() method
      await _sendCommandBangle('require("pulsewatch").start()');

      print("🎬 Auto-started recording on Bangle.js");
    } catch (e) {
      print("⚠️ Could not auto-start recording: $e");
      // Non-fatal error - connection still works
    }
  }

  // SYNC DATA (Device-specific)
  Future<void> syncDataFromWatch() async {
    if (!isConnected || _isTransferring) {
      print("❌ Cannot sync: not connected or already transferring");
      return;
    }

    if (_currentDeviceType == DeviceType.bangleJS) {
      await _syncFromBangleJS();
    } else if (_currentDeviceType == DeviceType.tWatch) {
      await _syncFromTWatch();
    } else {
      print("❌ Unknown device type, cannot sync");
    }
  }

  // BANGLE.JS SYNC (File-based transfer)
  Future<void> _syncFromBangleJS() async {
    _isTransferring = true;
    _totalRecords = 0;
    _receiveBuffer = '';
    _fileList = [];
    _currentFileIndex = 0;
    
    _transferProgressController.add(TransferProgress(
      currentFile: 0,
      totalFiles: 0,
      recordsReceived: 0,
      status: 'Requesting file list from Bangle.js...',
    ));

    try {
      // Get list of CSV files from watch Storage
      await _sendCommandBangle(r'print(require("Storage").list(/^pw.*\.csv$/).join(","))');
      
      await Future.delayed(Duration(milliseconds: 1000));
      
      if (_receiveBuffer.isNotEmpty) {
        String fileListStr = _receiveBuffer.trim();
        _receiveBuffer = '';
        
        if (fileListStr.isNotEmpty && fileListStr != 'undefined') {
          _fileList = fileListStr.split(',').where((f) => f.isNotEmpty).toList();
          print("📂 Found ${_fileList.length} files: $_fileList");
          
          if (_fileList.isEmpty) {
            _completeTransfer('No data files found on Bangle.js');
            return;
          }
          
          _transferProgressController.add(TransferProgress(
            currentFile: 0,
            totalFiles: _fileList.length,
            recordsReceived: 0,
            status: 'Found ${_fileList.length} files. Starting transfer...',
          ));
          
          await _readNextFileBangle();
        } else {
          _completeTransfer('No data files found on Bangle.js');
        }
      } else {
        _completeTransfer('No response from Bangle.js');
      }
      
    } catch (e) {
      print("Sync error: $e");
      _isTransferring = false;
      _transferProgressController.add(TransferProgress(
        currentFile: 0,
        totalFiles: 0,
        recordsReceived: _totalRecords,
        status: 'Sync failed: $e',
      ));
    }
  }

  Future<void> _readNextFileBangle() async {
    if (_currentFileIndex >= _fileList.length) {
      _completeTransfer('✅ Bangle.js sync complete! $_totalRecords records saved.');
      return;
    }
    
    String filename = _fileList[_currentFileIndex];
    print("📥 Reading file: $filename");
    
    _transferProgressController.add(TransferProgress(
      currentFile: _currentFileIndex + 1,
      totalFiles: _fileList.length,
      recordsReceived: _totalRecords,
      status: 'Reading file ${_currentFileIndex + 1}/${_fileList.length}...',
    ));
    
    _receiveBuffer = '';
    await _sendCommandBangle('print(require("Storage").read("$filename"))');
    await Future.delayed(Duration(milliseconds: 2000));
    
    if (_receiveBuffer.isNotEmpty) {
      await _processFileData(_receiveBuffer);
      _receiveBuffer = '';
    }
    
    _currentFileIndex++;
    await Future.delayed(Duration(milliseconds: 500));
    await _readNextFileBangle();
  }

  Future<void> _processFileData(String csvData) async {
    List<String> lines = csvData.split('\n');
    String? deviceId = _connectedDevice?.remoteId.toString();
    
    for (String line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('timestamp,')) continue;
      
      try {
        List<String> parts = line.split(',');
        
        if (parts.length >= 6) {
          int timestamp = int.parse(parts[0]);
          int bpm = int.parse(parts[1]);
          int confidence = int.parse(parts[2]);
          int accelX = int.parse(parts[3]);
          int accelY = int.parse(parts[4]);
          int accelZ = int.parse(parts[5]);
          
          await _db.insertHeartRateWithTimestamp(timestamp, bpm, confidence, deviceId);
          await _db.insertAccelerometerWithTimestamp(timestamp, accelX, accelY, accelZ, deviceId);
          
          _totalRecords++;
        }
      } catch (e) {
        print("Error parsing line: $line - $e");
      }
    }
    
    print("✅ Processed ${_totalRecords} total records");
  }

  // T-WATCH SYNC (Already streaming real-time)
  Future<void> _syncFromTWatch() async {
    // T-Watch is already streaming data in real-time
    // Just report current status
    _transferProgressController.add(TransferProgress(
      currentFile: 0,
      totalFiles: 0,
      recordsReceived: _totalRecords,
      status: 'T-Watch is streaming live data. Total: $_totalRecords readings.',
    ));
    
    print("ℹ️ T-Watch streams continuously - no manual sync needed");
  }

  void _completeTransfer(String message) {
    _isTransferring = false;
    _transferProgressController.add(TransferProgress(
      currentFile: _fileList.length,
      totalFiles: _fileList.length,
      recordsReceived: _totalRecords,
      status: message,
    ));
  }

  // DISCONNECT
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
      _bangleUartTxCharacteristic = null;
      _bangleUartRxCharacteristic = null;
      _tWatchAccelCharacteristic = null;
      _tWatchHRCharacteristic = null;
      _currentDeviceType = DeviceType.unknown;
    }
  }

  void dispose() {
    _devicesController.close();
    _connectionStateController.close();
    _transferProgressController.close();
  }
}

// Transfer progress model
class TransferProgress {
  final int currentFile;
  final int totalFiles;
  final int recordsReceived;
  final String status;

  TransferProgress({
    required this.currentFile,
    required this.totalFiles,
    required this.recordsReceived,
    required this.status,
  });

  double get progress {
    if (totalFiles == 0) return 0.0;
    return currentFile / totalFiles;
  }
}