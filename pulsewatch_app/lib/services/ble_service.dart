import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'database_helper.dart';
import 'hrv_feature_extractor.dart';

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
  final _liveBpmController = StreamController<int>.broadcast();
  final _liveSampleController = StreamController<BpmSample>.broadcast();

  // Streams
  Stream<List<ScanResult>> get devicesStream => _devicesController.stream;
  Stream<BluetoothConnectionState> get connectionStateStream => _connectionStateController.stream;
  Stream<TransferProgress> get transferProgressStream => _transferProgressController.stream;
  Stream<int> get liveBpmStream => _liveBpmController.stream;
  Stream<BpmSample> get liveSampleStream => _liveSampleController.stream;

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

  // Set while _readNextFileBangle() is waiting on a specific file's content.
  // The notification listener resolves this the moment it sees that file's
  // "SYNC_DONE:<filename>" sentinel line (appended after the read command,
  // see _readNextFileBangle) — this is what lets us know a file's content
  // has arrived *completely*, instead of guessing with a fixed delay that
  // could cut off a slow transfer mid-file.
  String? _expectedSyncFilename;
  Completer<void>? _fileReceivedCompleter;

  // Reassembles complete lines out of BLE notification fragments. A single
  // CSV line (30-40+ chars) routinely exceeds one BLE packet's payload, so
  // notifications cannot be assumed to contain whole lines — without this,
  // a line split mid-notification either fails to parse (dropped sample)
  // or, worse, parses into garbage that gets a false comma-count match.
  String _uartCarry = '';

  // Cached most-recent accelerometer reading for T-Watch, whose HR and
  // accel values arrive on separate characteristics/notifications rather
  // than one combined line like Bangle.js — needed to build a BpmSample.
  double _tWatchLastAx = 0, _tWatchLastAy = 0, _tWatchLastAz = 0;

  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<BluetoothConnectionState>? _deviceConnectionSubscription;

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

    // Cancel any previous listener first — without this, every scan added
    // another permanent listener on FlutterBluePlus.scanResults that was
    // never cleaned up.
    await _scanResultsSubscription?.cancel();
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
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

      // Cancel any previous device's listener first — reconnects (manual or
      // auto-reconnect on app resume) otherwise stacked up a new listener
      // on every call without ever releasing the old one.
      await _deviceConnectionSubscription?.cancel();
      _deviceConnectionSubscription = device.connectionState.listen((state) {
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

      // Remember this device for auto-reconnect on next app open
      await _saveLastDevice(device);

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
      _uartCarry = '';
      await _bangleUartRxCharacteristic!.setNotifyValue(true);
      _bangleUartRxCharacteristic!.lastValueStream.listen((value) async {
        if (value.isEmpty) return;

        // Reassemble fragments into complete lines first. A BLE notification
        // may end mid-line — only fully-terminated lines are processed here;
        // any trailing partial line is carried over to the next notification.
        _uartCarry += utf8.decode(value);
        List<String> lines = _uartCarry.split('\n');
        _uartCarry = lines.removeLast();

        for (String line in lines) {
          line = line.trim();
          if (line.isEmpty) continue;

          // While a file sync is in flight, everything goes to the file
          // buffer — a file's echoed data rows are byte-for-byte the same
          // shape as a live sample (7 comma-separated ints), so there is no
          // reliable way to tell them apart by content alone. Treating some
          // of them as "live" here is exactly what used to make the file
          // buffer end up empty (every real data line took the live
          // fast-path and never reached _receiveBuffer), which made the
          // fixed-delay-based "is this file done yet" guess in
          // _readNextFileBangle unverifiable — a real risk now that a
          // confirmed-complete read is what gates deleting the file off the
          // watch.
          if (_isTransferring) {
            if (_expectedSyncFilename != null &&
                line == 'SYNC_DONE:$_expectedSyncFilename') {
              _fileReceivedCompleter?.complete();
            } else {
              _receiveBuffer += line + '\n';
            }
            continue;
          }

          // 🔍 Try to parse as live CSV data (7 comma-separated integers)
          List<String> parts = line.split(',');
          if (parts.length == 7) {
            try {
              // Parse all 7 fields: timestamp,bpm,rr_interval_ms,confidence,x,y,z
              int timestamp = int.parse(parts[0]);
              int bpm = int.parse(parts[1]);
              int rrIntervalMs = int.parse(parts[2]);
              int confidence = int.parse(parts[3]);
              int x = int.parse(parts[4]);
              int y = int.parse(parts[5]);
              int z = int.parse(parts[6]);

              // ✅ LIVE DATA — save to DB immediately
              String? deviceId = _connectedDevice?.remoteId.toString();
              await _db.insertHeartRateWithTimestamp(timestamp, bpm, rrIntervalMs, confidence, deviceId);
              await _db.insertAccelerometerWithTimestamp(timestamp, x, y, z, deviceId);
              _liveBpmController.add(bpm);
              _liveSampleController.add(BpmSample(
                time: DateTime.fromMillisecondsSinceEpoch(timestamp),
                bpm: bpm.toDouble(),
                ax: x.toDouble(),
                ay: y.toDouble(),
                az: z.toDouble(),
                rr: rrIntervalMs.toDouble(),
              ));

              // A file sync (if any) already took the branch above and
              // `continue`d, so reaching here always means live streaming.
              _totalRecords++;
              _transferProgressController.add(TransferProgress(
                currentFile: 0,
                totalFiles: 0,
                recordsReceived: _totalRecords,
                status: 'Live HR: $bpm BPM • $_totalRecords readings',
              ));
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

              _tWatchLastAx = x.toDouble();
              _tWatchLastAy = y.toDouble();
              _tWatchLastAz = z.toDouble();

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
            _liveBpmController.add(bpm);
            // T-Watch has no RR-interval output, unlike Bangle.js — HRV
            // features fall back to the BPM-derived approximation for it.
            _liveSampleController.add(BpmSample(
              time: DateTime.now(),
              bpm: bpm.toDouble(),
              ax: _tWatchLastAx,
              ay: _tWatchLastAy,
              az: _tWatchLastAz,
            ));
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
    _expectedSyncFilename = filename;
    _fileReceivedCompleter = Completer<void>();

    // The sentinel print (sent right after the read) tells us precisely
    // when this file's content has fully arrived. A fixed delay here can't
    // distinguish "small file, done early" from "large/slow transfer, still
    // arriving" — and cutting a read off early would mean asking the watch
    // to erase a file whose tail never actually reached the phone.
    await _sendCommandBangle(
      'print(require("Storage").read("$filename"));print("SYNC_DONE:$filename")',
    );

    bool receivedFully = true;
    try {
      await _fileReceivedCompleter!.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      receivedFully = false;
      print("⚠️ Timed out waiting for $filename — leaving it on the watch to retry next sync");
    }
    _expectedSyncFilename = null;
    _fileReceivedCompleter = null;

    if (receivedFully) {
      final rowsInserted = await _processFileData(_receiveBuffer);
      _receiveBuffer = '';

      if (rowsInserted > 0) {
        // Erase only now that the rows are confirmed durably in the phone's
        // DB. Fire-and-forget is intentional: if this command is lost or
        // fails, the file simply stays on the watch and gets synced (and
        // its erase re-attempted) again next time — that can duplicate rows
        // on a later re-sync, but it can never lose data, which is the
        // property that matters here.
        await _sendCommandBangle('require("Storage").erase("$filename")');
      } else {
        print("⚠️ $filename produced 0 parseable rows — leaving it on the watch");
      }
    }

    _currentFileIndex++;
    await Future.delayed(Duration(milliseconds: 300));
    await _readNextFileBangle();
  }

  // Returns the number of rows successfully parsed and inserted, so the
  // caller can gate deleting the source file off the watch on this being
  // >0 rather than just assuming the read succeeded.
  Future<int> _processFileData(String csvData) async {
    List<String> lines = csvData.split('\n');
    String? deviceId = _connectedDevice?.remoteId.toString();
    int rowsInserted = 0;

    for (String line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('timestamp,')) continue;

      try {
        List<String> parts = line.split(',');

        if (parts.length >= 7) {
          int timestamp = int.parse(parts[0]);
          int bpm = int.parse(parts[1]);
          int rrIntervalMs = int.parse(parts[2]);
          int confidence = int.parse(parts[3]);
          int accelX = int.parse(parts[4]);
          int accelY = int.parse(parts[5]);
          int accelZ = int.parse(parts[6]);
          
          await _db.insertHeartRateWithTimestamp(timestamp, bpm, rrIntervalMs, confidence, deviceId);
          await _db.insertAccelerometerWithTimestamp(timestamp, accelX, accelY, accelZ, deviceId);

          _totalRecords++;
          rowsInserted++;
        }
      } catch (e) {
        print("Error parsing line: $line - $e");
      }
    }

    print("✅ Processed $rowsInserted rows from this file (total $_totalRecords)");
    return rowsInserted;
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

  // LAST DEVICE PERSISTENCE ────────────────────────────────────────────────

  Future<void> _saveLastDevice(BluetoothDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_ble_device_id', device.remoteId.toString());
    await prefs.setString('last_ble_device_name', device.platformName);
  }

  Future<String?> _getLastDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('last_ble_device_id');
  }

  // AUTO-RECONNECT ──────────────────────────────────────────────────────────

  /// Called on app resume. Tries to reconnect to the last known device:
  ///   1. Check if the OS already has it connected (fast path).
  ///   2. Otherwise scan for up to 8 seconds and connect if found.
  Future<void> tryAutoReconnect() async {
    if (isConnected) return;

    final savedId = await _getLastDeviceId();
    if (savedId == null) return;

    // Fast path: OS-level connection still active
    for (final device in FlutterBluePlus.connectedDevices) {
      if (device.remoteId.toString() == savedId) {
        await connectToDevice(device);
        return;
      }
    }

    // Slow path: scan briefly
    final completer = Completer<BluetoothDevice?>();
    Timer(const Duration(seconds: 8), () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId.toString() == savedId) {
          if (!completer.isCompleted) completer.complete(r.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      final found = await completer.future;
      if (found != null) await connectToDevice(found);
    } catch (_) {
      // BLE not available or scan failed — ignore silently
    } finally {
      sub.cancel();
    }
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

  Future<void> sendRiskAlarm() async {
    await _sendCommandBangle(
      'Bangle.buzz(300,0.4);'
      'E.showMessage(\"Risk alert\",\"PulseWatch\");'
      'setTimeout(function(){Bangle.setUI();},4000);'
    );
  }

  void dispose() {
    _devicesController.close();
    _connectionStateController.close();
    _transferProgressController.close();
    _liveBpmController.close();
    _liveSampleController.close();
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