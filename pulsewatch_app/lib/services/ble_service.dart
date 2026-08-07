import 'dart:async';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'background_sync_service.dart';
import 'connection_status_service.dart';
import 'database_helper.dart';
import 'foreground_task_handler.dart';
import 'sync_log_service.dart';

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

  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<BluetoothConnectionState>? _deviceConnectionSubscription;

  // Which kind of call is currently holding the connection — needed by the
  // connectionState listener below (an unexpected-drop handler with no
  // parameters of its own) to log a background vs. interactive drop
  // correctly. See connectToDevice's [loggedAs] parameter.
  SyncSource _activeConnectionSource = SyncSource.interactive;

  // True for the entire duration of any connectToDevice() call (from
  // whichever isolate/trigger — interactive tap, tryAutoReconnect,
  // performBackgroundSync, or the connectionState listener's own silent-
  // reconnect recovery below). Guards against a real bug found in testing:
  // the listener is attached *before* device.connect() is awaited, so the
  // underlying stream can deliver its "connected" event — and run the
  // listener's silent-reconnect branch — before the awaiting code resumes
  // and sets _connectedDevice itself. That race let a normal, ordinary
  // connect re-enter connectToDevice() a second time for the same device
  // while the first call was still in progress, corrupting shared state
  // (_deviceConnectionSubscription got cancelled and replaced out from
  // under the in-flight call) and hanging the "Connecting…" spinner
  // forever. Checking this flag (set synchronously before the listener
  // even attaches) closes that window completely — see the listener below.
  bool _connectAttemptInFlight = false;

  // Fires every 2 minutes while an *interactive* connection is active. Two
  // jobs, both needing the connection to still be held open:
  //   1. Re-run the file-sync flow, so a long-held interactive session keeps
  //      pulling newly flushed watch files instead of only ever syncing once
  //      at connect time. This matters specifically because there's no more
  //      live BLE push (removed along with the phone's live-BPM UI) — file
  //      sync is now the *only* way data reaches the phone, and the watch
  //      only has something new to sync every ~5 minutes (its own flash
  //      checkpoint interval, bangle/lib.js's CONFIG.saveInterval).
  //   2. Force a fresh reconnect the moment
  //      ConnectionStatusService.isStale() says the link has gone silently
  //      dead (see that method's doc comment) — polling on this same cadence
  //      is also what keeps isStale()'s "no new reading" signal meaningful,
  //      since job 1 is what makes new readings arrive at all now.
  // Only meaningful for interactive sessions: this Timer lives in whatever
  // isolate created it, and a WorkManager background isolate's lifetime is
  // too short for a periodic timer to ever fire again after
  // performBackgroundSync() returns — that path already does its own sync
  // and isStale() check on each scheduled invocation instead (see
  // performBackgroundSync). This is purely about getting fresher data and
  // faster stale-link recovery than waiting for the next ~15-30min
  // background cycle while the app is actually open and being watched.
  Timer? _interactiveSyncTimer;

  // True only for the duration of an explicit disconnect() call — lets the
  // connectionState listener tell "we asked for this" apart from "the link
  // just died on its own", which matters a lot: those two cases used to be
  // handled identically (silently), and that's exactly what let a dead
  // connection sit behind a foreground service notification that still said
  // "Connected" for hours. See the listener below for the full story.
  bool _disconnectRequested = false;

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

  String _deviceLabelFor(DeviceType type) {
    switch (type) {
      case DeviceType.bangleJS:
        return 'Bangle.js';
      case DeviceType.tWatch:
        return 'T-Watch';
      case DeviceType.unknown:
        return 'watch';
    }
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
  //
  // [autoConnect] selects between two genuinely different flutter_blue_plus
  // connection modes (see bluetooth_device.dart's connect()/connectionState
  // doc comments) — this isn't a minor flag:
  //   - false (default): a direct connection. connect() only resolves once
  //     actually connected (or the timeout fires). Used for the manual
  //     "user tapped a device they just scanned, it's in range right now"
  //     flow in device_screen.dart, where we want fast, definite feedback.
  //   - true: hands reconnection off to the OS's Bluetooth stack, which
  //     keeps retrying in the background whenever the device comes back
  //     into range, instead of us having to actively re-scan. The tradeoff
  //     (per flutter_blue_plus) is that connect() then always returns
  //     immediately regardless of whether a connection has actually been
  //     established — so we can't assume "connected" just because connect()
  //     resolved, and instead wait on connectionState ourselves below. Used
  //     for tryAutoReconnect(), where the watch may not be in range yet.
  //
  // [awaitSync] controls whether this call waits for syncDataFromWatch() to
  // finish before returning:
  //   - false (default, interactive callers): fire-and-forget. device_screen
  //     shows a blocking "connecting…" spinner keyed to this function's
  //     return, and a backlog sync can take a while — it shouldn't hold
  //     that up. Progress is still observable via transferProgressStream.
  //   - true (background_sync_service.dart only): the WorkManager task needs
  //     a definite "are we done yet" signal so it knows when it's safe to
  //     disconnect and hand a result back to WorkManager (whose own
  //     retry/backoff depends on that result being accurate) — see
  //     performBackgroundSync().
  //
  // [loggedAs] tags every SyncLogService entry this call produces so the
  // in-app diagnostics view (device_screen.dart) can distinguish "the user
  // was watching this fail live" from "this failed unattended overnight".
  //
  // Each stage below (BLE connect, characteristic discovery, sync,
  // foreground service) is caught and logged separately rather than behind
  // one umbrella try/catch. That matters for two reasons: (1) a failure in
  // the foreground service or the sync step must NOT be reported as
  // "connection failed" when the BLE link itself is genuinely up — the old
  // single catch-all conflated those, so a foreground-service hiccup showed
  // the user the exact same generic error as a real failed pairing, and
  // (2) SyncLogService.lastFailure() can then show a message that actually
  // names what broke instead of a raw, undifferentiated exception string.
  Future<bool> connectToDevice(
    BluetoothDevice device, {
    bool autoConnect = false,
    bool awaitSync = false,
    SyncSource loggedAs = SyncSource.interactive,
    Duration autoConnectTimeout = const Duration(seconds: 15),
  }) async {
    // Reject outright if another attempt is already running, rather than
    // just guarding the listener's own silent-reconnect branch as before.
    // Real-device logs caught the gap this closes: MainNavigation's
    // initState *and* didChangeAppLifecycleState can both call
    // tryAutoReconnect() within milliseconds of each other during a cold
    // start, and each one calls connectToDevice() directly — a case
    // _connectAttemptInFlight didn't cover previously, since it was only
    // read inside the connectionState listener, not checked here at entry.
    // The result was two connectToDevice() calls running concurrently on
    // the same device, visibly duplicating service discovery and
    // characteristic setup a few milliseconds apart in the log.
    if (_connectAttemptInFlight) {
      await _log(
        source: loggedAs,
        success: false,
        stage: SyncStage.connect,
        message: 'Skipped — a connection attempt was already in progress for this device.',
      );
      return false;
    }

    // Set synchronously, before the connectionState listener below is even
    // attached — see _connectAttemptInFlight's doc comment for the earlier
    // race this also closes. Reset in the `finally` at the bottom, so it
    // clears on every return path (success or any of the failure returns)
    // without relying on each one to remember to do it individually.
    _connectAttemptInFlight = true;
    try {
      return await _connectToDeviceImpl(
        device,
        autoConnect: autoConnect,
        awaitSync: awaitSync,
        loggedAs: loggedAs,
        autoConnectTimeout: autoConnectTimeout,
      );
    } finally {
      _connectAttemptInFlight = false;
    }
  }

  Future<bool> _connectToDeviceImpl(
    BluetoothDevice device, {
    required bool autoConnect,
    required bool awaitSync,
    required SyncSource loggedAs,
    Duration autoConnectTimeout = const Duration(seconds: 15),
  }) async {
    _currentDeviceType = _detectDeviceType(device.platformName);
    print("🔍 Detected device type: $_currentDeviceType");

    _activeConnectionSource = loggedAs;

    // Cancel any previous device's listener first — reconnects (manual or
    // auto-reconnect on app resume) otherwise stacked up a new listener
    // on every call without ever releasing the old one.
    await _deviceConnectionSubscription?.cancel();
    _deviceConnectionSubscription = device.connectionState.listen((state) {
      _connectionStateController.add(state);

      if (state == BluetoothConnectionState.connected &&
          _connectedDevice == null &&
          !_connectAttemptInFlight) {
        // The OS's autoConnect — kicked off from the unexpected-drop branch
        // below — completed on its own, outside of an explicit
        // connectToDevice() call (that path sets _connectedDevice
        // synchronously right after its own connect succeeds, which is
        // what the null check here is distinguishing against — and
        // _connectAttemptInFlight rules out the race where this event
        // arrives *before* that assignment has happened yet; see that
        // field's doc comment). Route back through the full connect flow
        // rather than duplicating a partial version of it here: it's cheap
        // since the device is already connected at the GATT level (this
        // mainly re-runs characteristic discovery — services aren't
        // guaranteed to survive a fresh GATT connection — and resumes
        // syncing), and reuses the exact same tested path a fresh connect
        // takes.
        unawaited(connectToDevice(
          device,
          autoConnect: true,
          loggedAs: _activeConnectionSource,
        ));
        return;
      }

      if (state == BluetoothConnectionState.disconnected) {
        // wasConnected distinguishes "the link actually dropped" from the
        // stream's initial/pre-connect "disconnected" event that fires the
        // instant this listener attaches (before device.connect() below
        // has even run) — without this check, that harmless startup event
        // would look identical to a real drop.
        final wasConnected = _connectedDevice != null;
        final droppedDeviceLabel = _deviceLabelFor(_currentDeviceType);
        _connectedDevice = null;
        _bangleUartTxCharacteristic = null;
        _bangleUartRxCharacteristic = null;
        _tWatchAccelCharacteristic = null;
        _tWatchHRCharacteristic = null;
        _currentDeviceType = DeviceType.unknown;

        // An unexpected drop — the watch went out of range, Android or the
        // watch's own Bluetooth stack silently killed the link, etc. — as
        // opposed to disconnect() being called on purpose (which sets
        // _disconnectRequested first; see disconnect() below).
        if (wasConnected && !_disconnectRequested) {
          unawaited(ConnectionStatusService.instance.setState(
            WatchConnectionState.reconnecting,
            deviceLabel: droppedDeviceLabel,
          ));
          unawaited(_log(
            source: _activeConnectionSource,
            success: false,
            stage: SyncStage.connect,
            message: 'Watch connection dropped unexpectedly — reconnecting automatically.',
          ));

          // Hand reconnection off to the OS *immediately* rather than
          // waiting for the next scheduled background-sync tick (which can
          // be 15-30+ minutes away). autoConnect:true doesn't poll or
          // scan — it registers with the Android Bluetooth stack, which
          // completes this on its own the moment the watch is back in
          // range, at near-zero battery cost. Completion is picked up by
          // the "connected" branch above. This used to not exist at all —
          // an unexpected drop previously did nothing until either the
          // user reopened the app or a background tick happened to fire,
          // which produced the multi-hour silent gaps seen in real
          // session exports.
          unawaited(device.connect(autoConnect: true, mtu: null).catchError((e) {
            print('Immediate auto-reconnect attempt failed to register: $e');
          }));
        } else if (!wasConnected && !_disconnectRequested) {
          // Not a drop from a live connection (most likely this stream's
          // initial pre-connect event) — nothing to report.
        }
      }
    });

    // STAGE 1 — the BLE link itself. If this fails, nothing below matters.
    try {
      if (autoConnect) {
        // mtu:null is required alongside autoConnect (flutter_blue_plus
        // asserts the two are incompatible) — a safe drop since this app
        // never calls requestMtu and doesn't rely on a negotiated MTU size.
        await device.connect(autoConnect: true, mtu: null);
        final state = await device.connectionState
            .firstWhere((s) => s == BluetoothConnectionState.connected)
            .timeout(
              autoConnectTimeout,
              onTimeout: () => BluetoothConnectionState.disconnected,
            );
        if (state != BluetoothConnectionState.connected) {
          await _log(
            source: loggedAs,
            success: false,
            stage: SyncStage.connect,
            message: 'Watch did not finish connecting within '
                '${autoConnectTimeout.inSeconds}s.',
          );
          await ConnectionStatusService.instance.setState(WatchConnectionState.disconnected);
          return false;
        }
      } else {
        await device.connect(timeout: const Duration(seconds: 15));
      }
      _connectedDevice = device;
    } catch (e) {
      await _log(
        source: loggedAs,
        success: false,
        stage: SyncStage.connect,
        message: 'Could not open a Bluetooth connection: $e',
      );
      await ConnectionStatusService.instance.setState(WatchConnectionState.disconnected);
      return false;
    }

    // STAGE 2 — find and subscribe to the characteristics this device type
    // needs. A failure here still means "connection failed" from the
    // user's point of view (there's nothing usable without this), so it
    // still returns false, but with a message that says *what* about the
    // device didn't match instead of an opaque exception.
    bool success;
    try {
      List<BluetoothService> services = await device.discoverServices();
      if (_currentDeviceType == DeviceType.bangleJS) {
        success = await _setupBangleJS(services);
      } else if (_currentDeviceType == DeviceType.tWatch) {
        success = await _setupTWatch(services);
      } else {
        // Unknown device - try both
        success = await _setupBangleJS(services) || await _setupTWatch(services);
      }
    } catch (e) {
      await _log(
        source: loggedAs,
        success: false,
        stage: SyncStage.characteristics,
        message: 'Connected, but reading the watch\'s Bluetooth services failed: $e',
      );
      await device.disconnect();
      return false;
    }

    if (!success) {
      await _log(
        source: loggedAs,
        success: false,
        stage: SyncStage.characteristics,
        message: "Connected, but this device doesn't expose the Bangle.js/T-Watch "
            'Bluetooth characteristics this app expects. Wrong device, or an '
            'unsupported firmware version?',
      );
      await device.disconnect();
      await ConnectionStatusService.instance.setState(WatchConnectionState.disconnected);
      return false;
    }

    print("✅ Connected successfully to $_currentDeviceType!");

    // Persist "really connected" immediately — the notification text
    // itself won't actually update until the foreground service exists
    // (see the explicit updateNotification() call after
    // _ensureForegroundServiceRunning() below), but the state is
    // authoritative from here regardless, since performBackgroundSync()
    // reads it directly rather than through the notification.
    unawaited(ConnectionStatusService.instance.setState(
      WatchConnectionState.connected,
      deviceLabel: _deviceLabelFor(_currentDeviceType),
    ));

    // From here on the BLE link is genuinely up — everything below is
    // best-effort and logged on its own, never turning a successful
    // connection into a false "connection failed" report.

    // Auto-start recording on Bangle.js
    if (_currentDeviceType == DeviceType.bangleJS) {
      // Must happen before any other command on this connection — see
      // _disableConsoleEcho's doc comment for why every command sent
      // afterward depends on this running first.
      await _disableConsoleEcho();
      await _autoStartRecording();
    }

    // Bond with the watch (idempotent — no-ops once already bonded). This
    // matters specifically for background reconnection: real-device testing
    // (see ARCHITECTURE.md's background sync section) showed an *unbonded*
    // BLE device gets far worse background treatment from Android than a
    // bonded one — `adb shell dumpsys bluetooth_manager` confirmed the
    // watch was never in the phone's bonded-devices list, and background
    // scans were being throttled down to seeing zero BLE devices of any
    // kind in a 25s window, while every interactive (foreground) scan
    // succeeded instantly. Once bonded, performBackgroundSync() skips
    // scanning entirely and uses autoConnect directly, which Android
    // handles via its own low-power whitelist-based background scanning —
    // built specifically for reconnecting to known/bonded companion
    // devices, and not subject to the same throttling as an app's active
    // startScan(). This will show Android's system pairing prompt the
    // first time it runs; Bangle.js uses "Just Works" BLE pairing (no PIN),
    // so it's a simple confirmation, not a code-entry flow.
    try {
      if (await device.bondState.first != BluetoothBondState.bonded) {
        await device.createBond();
      }
    } catch (e) {
      await _log(
        source: loggedAs,
        success: false,
        stage: SyncStage.connect,
        message: 'Connected, but pairing/bonding with the watch failed: $e. '
            'Background reconnection will be less reliable until this '
            'succeeds on a future connect.',
      );
    }

    // Remember this device for auto-reconnect on next app open, and make
    // sure the WorkManager periodic background sync (the actual data-loss
    // guarantee for the hours the app isn't open — see
    // background_sync_service.dart) is scheduled for it. Skipped when this
    // call itself came from performBackgroundSync(): that only ever runs
    // because the periodic task is already scheduled and executing, so
    // re-registering here would just be a redundant call into WorkManager
    // from inside its own callback isolate for no benefit.
    try {
      await _saveLastDevice(device);
      if (loggedAs == SyncSource.interactive) {
        await BackgroundSyncService.instance.ensureScheduled();
      }
    } catch (e) {
      await _log(
        source: loggedAs,
        success: false,
        stage: SyncStage.connect,
        message: 'Connected, but failed to persist this device for auto-reconnect: $e',
      );
    }

    // Pull in anything the watch buffered to flash while we were
    // disconnected — live streaming is the only thing that otherwise
    // reaches the phone's DB, so a connection drop used to mean that
    // window of data just sat on the watch, invisible to the 48h
    // coverage count, until something happened to sync it. See [awaitSync]
    // above for why interactive and background callers differ here.
    if (awaitSync) {
      try {
        await syncDataFromWatch().timeout(const Duration(minutes: 2));
      } catch (e) {
        await _log(
          source: loggedAs,
          success: false,
          stage: SyncStage.sync,
          message: 'Connected, but pulling data from the watch failed or timed out: $e',
          recordsSynced: _totalRecords,
        );
      }
    } else {
      unawaited(syncDataFromWatch());
    }

    // Runs continuously from the first successful connect (of any kind)
    // until an explicit disconnect() — see that method's [stopForegroundService]
    // parameter for why performBackgroundSync's periodic cycles don't tear
    // it down. It's a status board, not the data-completeness mechanism:
    // that guarantee comes from the periodic WorkManager sync scheduled
    // above, which works even if this service — or the whole process —
    // gets killed. A failure to start it here is therefore logged but
    // non-fatal to this connection attempt.
    try {
      await _ensureForegroundServiceRunning();
      // setState() above already ran before the service necessarily
      // existed, so its notification-text update was a no-op then — apply
      // it for real now that the service is confirmed running.
      await ConnectionStatusService.instance.updateNotification();
    } catch (e) {
      await _log(
        source: loggedAs,
        success: false,
        stage: SyncStage.foregroundService,
        message: 'Connected and syncing, but could not start the background '
            'recording notification: $e',
      );
    }

    await _log(
      source: loggedAs,
      success: true,
      stage: SyncStage.connect,
      message: 'Connected to $_currentDeviceType and started sync.',
      recordsSynced: _totalRecords,
    );

    // Background cycles are too short-lived for a periodic Timer to be
    // useful (see _interactiveSyncTimer's doc comment) — they already
    // get their own sync + isStale() check on their next scheduled
    // invocation.
    if (loggedAs == SyncSource.interactive) {
      _startInteractiveSyncTimer();
    }

    return true;
  }

  Future<void> _log({
    required SyncSource source,
    required bool success,
    required String stage,
    required String message,
    int recordsSynced = 0,
  }) {
    return SyncLogService.instance.record(
      source: source,
      success: success,
      stage: stage,
      message: message,
      recordsSynced: recordsSynced,
    );
  }

  void _startInteractiveSyncTimer() {
    _interactiveSyncTimer?.cancel();
    _interactiveSyncTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
      // Don't pile a watchdog-triggered reconnect on top of a connect
      // that's already in progress for any reason — see
      // _connectAttemptInFlight's doc comment for the hang this exact
      // kind of overlap caused before it existed.
      if (_connectAttemptInFlight) return;
      if (_connectedDevice == null) return;

      // Pull anything the watch has newly flushed to flash since the last
      // sync. Most ticks will find nothing (the watch only flushes every
      // ~5 minutes), which is a cheap, fast no-op — syncDataFromWatch()
      // itself no-ops immediately if a transfer is already in flight.
      unawaited(syncDataFromWatch());

      if (await ConnectionStatusService.instance.isStale()) {
        print('⚠️ Connection looks stale (connected, but no reading despite repeated sync attempts) — forcing a full disconnect+reconnect.');
        await _log(
          source: _activeConnectionSource,
          success: false,
          stage: SyncStage.connect,
          message: 'No reading despite appearing connected and repeated sync attempts — '
              'forcing a full disconnect+reconnect.',
        );
        unawaited(_forceReconnect());
      }
    });
  }

  void _stopInteractiveSyncTimer() {
    _interactiveSyncTimer?.cancel();
    _interactiveSyncTimer = null;
  }

  /// Recovery for a *stale* connection (see ConnectionStatusService.isStale)
  /// — deliberately a real disconnect followed by a fresh connect, not just
  /// calling connect() again on top of a link Android still reports as
  /// connected.
  ///
  /// The first version of this fix did the latter, and real testing showed
  /// it wasn't enough: readings stayed near-zero and staleness kept
  /// re-triggering every few minutes, which is the signature of Android's
  /// BLE stack holding a "zombie" GATT client — one that still reports
  /// CONNECTED and answers discoverServices()/setNotifyValue() calls
  /// (often from a cached state) without actually delivering notifications
  /// anymore. Simply calling connect() again on a link Android believes is
  /// already open can be a no-op that never rebuilds the underlying native
  /// GATT client, which is exactly why the "reconnect" kept *looking*
  /// successful (the log said "Connected... started sync") while nothing
  /// actually changed. An explicit disconnect() first forces Android to
  /// genuinely tear the old client down before a new one is requested.
  Future<void> _forceReconnect() async {
    final device = _connectedDevice;
    if (device == null) return;

    // stopForegroundService: false — this is a recovery within the same
    // session, not the user ending it; the notification/status board
    // should stay up throughout.
    await disconnect(stopForegroundService: false);

    // Give the OS a moment to actually release the old GATT client before
    // asking for a new one — reconnecting immediately risks colliding with
    // teardown still in progress.
    await Future.delayed(const Duration(seconds: 2));

    await connectToDevice(device, autoConnect: true, loggedAs: _activeConnectionSource);
  }

  // FOREGROUND SERVICE ────────────────────────────────────────────────────
  //
  // A live status board, not a static "recording" banner: its title/text
  // reflect ConnectionStatusService's real state (connected/reconnecting/
  // disconnected) and how long ago the last reading actually arrived, and
  // get refreshed both immediately on every state change (see
  // ConnectionStatusService.setState) and periodically — every 60s, via
  // foreground_task_handler.dart's onRepeatEvent — so "last reading Xm ago"
  // stays current even when nothing else has changed. Before this, the
  // notification text was set once at startService() and never touched
  // again, which the user correctly called out as "hardcoded" — it kept
  // saying "Connected" for hours after the watch had actually disconnected.
  //
  // Runs continuously from the first successful connect (of any kind, see
  // connectToDevice) until an explicit disconnect() — see that method's
  // [stopForegroundService] parameter. It does NOT hold a live BLE
  // connection open for that whole time (performBackgroundSync's cycles
  // connect, sync, and disconnect the actual radio each time — see that
  // method) — only the lightweight notification/process persists, which is
  // what makes "is the app actually running in the background at all"
  // honestly answerable by just looking at the notification tray, without
  // reintroducing the battery/Doze problems of holding a GATT connection
  // open continuously.
  static const _kBatteryExemptionAsked = 'battery_exemption_asked';

  Future<void> _ensureForegroundServiceRunning() async {
    if (!Platform.isAndroid) return;

    if (!FlutterForegroundTask.isInitialized) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'pulsewatch_recording',
          channelName: 'Recording Status',
          channelDescription:
              'Shows PulseWatch\'s real connection status and time since the '
              'last reading from your watch.',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          // Drives foreground_task_handler.dart's onRepeatEvent, which
          // refreshes "last reading Xm ago" every 60s even when no
          // connect/disconnect event happened to trigger an update itself.
          eventAction: ForegroundTaskEventAction.repeat(60000),
        ),
      );
    }

    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      // Placeholder — overwritten within moments by
      // ConnectionStatusService.updateNotification(), called right after
      // this returns (see connectToDevice). Kept generic rather than
      // claiming a connection state this function itself doesn't know yet.
      notificationTitle: 'PulseWatch',
      notificationText: 'Starting…',
      callback: foregroundTaskCallback,
    );
  }

  /// True if the user hasn't already been offered the battery-optimization
  /// exemption prompt, and the app isn't already exempted. Checked from the
  /// UI (home_screen.dart) after a successful connect, since showing the
  /// explanatory dialog needs a BuildContext this service doesn't have.
  Future<bool> needsBatteryExemptionPrompt() async {
    if (!Platform.isAndroid) return false;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kBatteryExemptionAsked) ?? false) return false;

    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    return !ignoring;
  }

  /// Records that the user has been asked, regardless of their answer, so
  /// we offer this once rather than nagging on every reconnect.
  Future<void> markBatteryExemptionAsked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBatteryExemptionAsked, true);
  }

  /// Opens the OS "ignore battery optimizations" request for this app.
  Future<void> requestBatteryExemption() =>
      FlutterForegroundTask.requestIgnoreBatteryOptimization();

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
  //
  // Everything the watch sends over this characteristic is now a response to
  // a command this app itself issued (file list, file read, echo(0)) — the
  // watch no longer pushes anything unsolicited (bangle/lib.js used to also
  // batch-push live samples every 15s; that's been removed). So there's no
  // longer any need to guess whether an incoming line is "live data" or
  // "file content" by parsing its shape: it's always either the SYNC_DONE
  // sentinel for an in-flight file read, or content that belongs in the
  // response buffer.
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

          if (_expectedSyncFilename != null &&
              line == 'SYNC_DONE:$_expectedSyncFilename') {
            _fileReceivedCompleter?.complete();
            continue;
          }

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

      // A write-with-response (withoutResponse: false, used here so we
      // know a command actually landed) is capped by BLE itself at 20
      // bytes of payload unless the connection negotiates a larger MTU or
      // uses GATT's "long write" (Prepare/Execute Write) queuing —
      // flutter_blue_plus enforces that cap client-side and throws rather
      // than silently truncating or auto-chunking. Confirmed via real
      // device logs: nearly every command this app actually sends exceeds
      // it — the 30-byte auto-start-recording command, and especially the
      // 50-80+ byte file-sync commands — so every one of those writes was
      // throwing and being swallowed by the catch below, meaning the watch
      // never received them at all. This was true before any change made
      // tonight; it just never surfaced because live streaming (the watch
      // pushing samples via notifications) doesn't depend on the phone
      // successfully writing anything.
      //
      // Rather than negotiate MTU (capped differently per phone/OEM, and
      // not guaranteed to be honored), this chunks into <=20-byte pieces
      // and writes them sequentially. That's safe here specifically
      // because Bangle.js's UART TX characteristic feeds straight into its
      // Espruino REPL as a plain byte stream parsed one line at a time —
      // it has no notion of "one BLE write = one unit", so it doesn't
      // matter how many separate writes a single command line arrives
      // across, only that the bytes and their order are preserved.
      const chunkSize = 20;
      for (var i = 0; i < bytes.length; i += chunkSize) {
        final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        await _bangleUartTxCharacteristic!.write(bytes.sublist(i, end), withoutResponse: false);
      }
      print("📤 Sent to Bangle: $command");
    } catch (e) {
      print("Error sending command: $e");
    }
  }

  /// Turns off Bangle.js's console echo for this connection. Without this,
  /// the Espruino REPL echoes every command back character-for-character
  /// (standard interactive-terminal behavior) plus an `=<result>` line —
  /// and both land in exactly the same buffer this app parses as "the
  /// watch's actual response" to a file-list/file-read request.
  ///
  /// Confirmed via real device logs, not theory: a "file list" response
  /// that should have been a clean comma-separated filename list instead
  /// contained the literal text of the *previous* command sent moments
  /// earlier, still arriving late and bleeding into the next response.
  /// This was invisible until the write-length fix above started letting
  /// commands actually reach the watch at all — before that, every command
  /// was silently dropped client-side, so this contamination never had a
  /// chance to show up.
  ///
  /// `echo(0)` is documented by Espruino for exactly this purpose:
  /// https://www.espruino.com/BLE+UART. Idempotent and cheap enough to
  /// call every connect rather than track whether a given watch session
  /// already had it set.
  Future<void> _disableConsoleEcho() async {
    _receiveBuffer = '';
    await _sendCommandBangle('echo(0)');
    // This one command is sent while echo is still on, so it gets one
    // echoed reply itself — give it a moment to arrive and discard it,
    // rather than let it leak into whatever's sent next.
    await Future.delayed(const Duration(milliseconds: 500));
    _receiveBuffer = '';
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
          // Filenames the watch actually creates always look like
          // "pw<timestamp>.csv" (see bangle/lib.js's saveData()). Filtering
          // to that exact shape — rather than accepting any non-empty
          // comma-separated entry — rejects stray live-streaming data that
          // can land in this same buffer: live samples keep flushing on
          // the watch's own independent 15s timer regardless of what the
          // phone is doing, so a batch of them can interleave with this
          // response. Confirmed via real device logs: without this, a
          // live-data batch was misparsed as "79 files" with names like
          // "83" or "-904\n1785955177285", none of which exist on the
          // watch, so every subsequent read came back empty.
          final filenamePattern = RegExp(r'^pw\d+\.csv$');
          _fileList = fileListStr
              .split(',')
              .where((f) => filenamePattern.hasMatch(f))
              .toList();
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

  // Returns the number of rows successfully *parsed* from this file, so
  // the caller can gate deleting the source file off the watch on this
  // being >0 rather than just assuming the read succeeded. Deliberately
  // counts parsed rows, not rows the DB actually inserted: a row already
  // present (e.g. this exact sample was already captured live before this
  // file got synced — see database_helper.dart's UNIQUE(timestamp,
  // device_id) index) is silently ignored at the DB layer rather than
  // duplicated, but the file has still been fully consumed either way, so
  // it's still correct to erase it.
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

  /// Fast-path + scan lookup for the last-known device, shared by
  /// [tryAutoReconnect] (interactive) and [performBackgroundSync]
  /// (WorkManager) so the two don't carry separate copies of "is it already
  /// connected at the OS level, otherwise scan briefly" that could quietly
  /// drift apart from each other over time.
  Future<BluetoothDevice?> _locateSavedDevice(
    String savedId, {
    required Duration scanTimeout,
  }) async {
    // Fast path: OS-level connection still active
    for (final device in FlutterBluePlus.connectedDevices) {
      if (device.remoteId.toString() == savedId) return device;
    }

    // Slow path: scan briefly
    final completer = Completer<BluetoothDevice?>();
    Timer(scanTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    int resultBatches = 0;
    final seenIds = <String>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      resultBatches++;
      for (final r in results) {
        seenIds.add(r.device.remoteId.toString());
        if (r.device.remoteId.toString() == savedId) {
          if (!completer.isCompleted) completer.complete(r.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: scanTimeout);
      print("🐛 startScan() returned without throwing — scan is running");
      final result = await completer.future;
      print("🐛 scan window ended: $resultBatches result batch(es), "
          "${seenIds.length} distinct device(s) seen: $seenIds");
      return result;
    } catch (e, st) {
      print("🐛 startScan() THREW: $e");
      print("🐛 $st");
      return null;
    } finally {
      await sub.cancel();
    }
  }

  /// Called on app resume. Tries to reconnect to the last known device.
  /// This alone is NOT what guarantees 48h data completeness anymore — see
  /// [performBackgroundSync] for the mechanism that covers the hours the
  /// app isn't open at all.
  Future<void> tryAutoReconnect() async {
    if (isConnected) return;

    final savedId = await _getLastDeviceId();
    if (savedId == null) return;

    final device = await _locateSavedDevice(
      savedId,
      scanTimeout: const Duration(seconds: 8),
    );
    if (device != null) {
      await connectToDevice(device, autoConnect: true);
    }
  }

  /// Called from the WorkManager periodic task (background_sync_service.dart)
  /// on a ~15-30 minute cadence, entirely independent of whether the app UI
  /// is open, backgrounded, or was swiped away. This — not the foreground
  /// service — is the actual guarantee that the phone is never more than
  /// one period behind the watch, regardless of what Android does to the
  /// app's process in between: the watch already checkpoints every 5
  /// minutes to flash on its own (see bangle/lib.js's saveData()), so a
  /// short periodic pull is sufficient and far cheaper than fighting to
  /// hold one BLE connection open continuously for 48h (which Android 12+
  /// actively works against — Doze can defer/drop connections outright,
  /// and a foreground service does not exempt an app from that).
  ///
  /// Differences from [tryAutoReconnect]:
  ///   - No longer tries to decide up front whether it's "safe to skip"
  ///     based on a reported connection state. That used to check
  ///     ConnectionStatusService (connected/stale/disconnected), but every
  ///     one of those signals turned out to be a *guess* built on indirect
  ///     evidence (a persisted flag, a timing heuristic on the last DB
  ///     write) — and real-device testing repeatedly showed the guess can
  ///     be wrong: Android's BLE stack can report a link as "connected"
  ///     for hours after it's actually gone silently dead (a zombie GATT
  ///     client that answers connect()/discoverServices() calls but never
  ///     delivers notifications again), which is exactly what starved
  ///     background sync for an hour in real testing — the skip check kept
  ///     trusting a state that was lying. Simpler and more robust to not
  ///     ask "do I think I'm connected" at all: just unconditionally force
  ///     a teardown of whatever might be lingering, then actually attempt a
  ///     fresh connect+sync every cycle, and let the result speak for
  ///     itself. SQLite's UNIQUE(timestamp, device_id) + insert-ignore (see
  ///     database_helper.dart) and the watch's erase-only-after-confirmed-
  ///     insert already make repeated/overlapping sync attempts harmless,
  ///     so there's nothing this skip check was protecting against that
  ///     isn't already handled at the data layer.
  ///   - The one real cost of not skipping: if an *interactive* session
  ///     genuinely has a healthy connection open right now, this cycle's
  ///     forced disconnect will briefly interrupt it. Accepted as a
  ///     reasonable tradeoff — the interactive side's own autoConnect +
  ///     connectionState listener (see connectToDevice) already reconnects
  ///     automatically within moments of any drop, planned or not.
  ///   - Awaits the full connect+sync cycle (`awaitSync: true`) instead of
  ///     firing sync in the background, since there's no UI spinner to
  ///     protect here and WorkManager needs a definite pass/fail result to
  ///     decide whether to back off and retry.
  ///   - Always disconnects again afterward — this connection exists only
  ///     for the duration of this one bounded sync, not until the next
  ///     scheduled run, which keeps each cycle short and battery-cheap
  ///     instead of an always-on radio.
  ///
  /// Returns true if either nothing needed doing (no saved device yet) or
  /// the sync completed; false if a device is known but couldn't be
  /// reached/synced this cycle, so WorkManager's own exponential backoff
  /// retries sooner than the next regular period.
  Future<bool> performBackgroundSync() async {
    if (!Platform.isAndroid) return true;

    final savedId = await _getLastDeviceId();
    if (savedId == null) return true; // No watch paired yet — nothing to do.

    // Force a real teardown of whatever might be lingering before trying
    // again — see _forceReconnect's doc comment for why simply reconnecting
    // on top of a link Android still considers "connected" can be a no-op
    // that never actually rebuilds the native GATT client.
    //
    // NOT disconnect() here — this method runs in the WorkManager
    // background isolate, which has its own fresh BleService() singleton
    // with its own empty _connectedDevice (always null: this isolate never
    // makes a connection of its own before this point, some other isolate
    // may have, possibly hours ago — see this file's isolate-boundary
    // comments elsewhere). disconnect()'s `if (_connectedDevice != null)`
    // guard would therefore always be false here, making it a silent no-op
    // that never actually tells Android to release the GATT link — this is
    // exactly what starved background sync for an hour in real testing: the
    // watch, still genuinely connected at the native level to whichever
    // isolate/session first connected it, had stopped advertising (a
    // connected BLE peripheral normally does), so every subsequent scan —
    // fast-path and real scan alike — came up empty, indefinitely, no
    // matter how long the scan window.
    //
    // BluetoothDevice.fromId() builds a device reference from just the
    // saved MAC/UUID, without needing to have discovered or connected it in
    // *this* isolate — Android's Bluetooth stack tracks GATT connections
    // per remote address, not per Dart object identity, so disconnecting
    // this constructed reference releases the same real link regardless of
    // which isolate created it. Unconditional and best-effort: harmless if
    // there was nothing real to tear down.
    try {
      await BluetoothDevice.fromId(savedId).disconnect();
    } catch (e) {
      // Expected when there was no real link — proceed to reconnect below.
    }
    await Future.delayed(const Duration(seconds: 2));

    // No scan here — deliberately. This used to call _locateSavedDevice()
    // (an active startScan()), but real-device testing proved that's
    // exactly what doesn't work from this isolate: `adb shell dumpsys
    // bluetooth_manager` showed the watch was never bonded, and Android
    // throttled background startScan() results down to seeing zero BLE
    // devices of any kind in a 25s window — not just missing the watch, an
    // empty scan entirely — while every interactive (foreground) scan
    // succeeded instantly. Since connectToDevice() now bonds with the watch
    // on every successful connect (see that method), BluetoothDevice.fromId()
    // + autoConnect below hands reconnection to Android's own low-power
    // whitelist-based background scanning — built specifically for
    // reconnecting to known/bonded companion devices — instead of an
    // active app-initiated scan that's subject to background throttling.
    final device = BluetoothDevice.fromId(savedId);
    final connected = await connectToDevice(
      device,
      autoConnect: true,
      awaitSync: true,
      loggedAs: SyncSource.background,
      // Generous relative to the interactive default (15s): this has to
      // cover Android's own background whitelist-scan latency, not just a
      // GATT handshake with an already-discovered device. Still well within
      // WorkManager's 4-minute hard ceiling (background_sync_service.dart).
      autoConnectTimeout: const Duration(seconds: 60),
    );

    // Leave the radio idle again afterward — see the doc comment above on
    // why this connection is bounded to one sync, not held open. The
    // notification/service itself stays up (stopForegroundService: false)
    // so it can keep showing "last reading Xm ago" between cycles — see
    // disconnect()'s doc comment.
    await disconnect(stopForegroundService: false);

    return connected;
  }

  // DISCONNECT
  //
  // [stopForegroundService] defaults to true for the normal case: an
  // explicit user-initiated disconnect (device_screen.dart) or a logout
  // really is "done, nothing more expected" and should tear down the
  // notification along with the BLE link.
  //
  // performBackgroundSync() passes false: each of its cycles connects,
  // syncs, and disconnects the actual radio, but the notification/process
  // is meant to persist continuously across cycles as a status board (see
  // the FOREGROUND SERVICE section above) — tearing it down here would mean
  // no visible sign the app is doing anything between periodic syncs, which
  // is the opposite of what it's for.
  Future<void> disconnect({bool stopForegroundService = true}) async {
    // Tells the connectionState listener above "this drop was requested",
    // so it doesn't also treat it as an unexpected one and log a
    // misleading "dropped unexpectedly" entry, or fire an immediate
    // OS-reconnect attempt, for what's actually a normal, planned
    // disconnect.
    _disconnectRequested = true;
    try {
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
        _connectedDevice = null;
        _bangleUartTxCharacteristic = null;
        _bangleUartRxCharacteristic = null;
        _tWatchAccelCharacteristic = null;
        _tWatchHRCharacteristic = null;
        _currentDeviceType = DeviceType.unknown;
      }

      await ConnectionStatusService.instance.setState(WatchConnectionState.disconnected);

      if (stopForegroundService) {
        await _stopForegroundServiceIfRunning();
        _stopInteractiveSyncTimer();
      }
    } finally {
      _disconnectRequested = false;
    }
  }

  /// Shared by [disconnect] and the connectionState listener's unexpected-
  /// drop handler in [connectToDevice] — see that listener's doc comment
  /// for why keeping this service's "running" state honest (stopped
  /// whenever the link is actually down, for any reason) matters well
  /// beyond the notification text itself.
  Future<void> _stopForegroundServiceIfRunning() async {
    if (Platform.isAndroid && await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
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