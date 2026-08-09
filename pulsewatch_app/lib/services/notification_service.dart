import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static DateTime? _lastHighAlert;
  static DateTime? _lastMedAlert;
  static const _cooldown = Duration(minutes: 5);

  // Upload alerts are fired from the WorkManager background isolate (see
  // background_sync_service.dart), which is a fresh Dart VM on every ~15
  // minute run — an in-memory cooldown like the two fields above would
  // reset every single time and never actually suppress anything there.
  // These use SharedPreferences instead so the cooldown survives across
  // isolates.
  static const _uploadAlertCooldown = Duration(hours: 3);

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings);

    const riskChannel = AndroidNotificationChannel(
      'risk_alerts',
      'Risk Alerts',
      description: 'Cardiac risk alerts from PulseWatch AI',
      importance: Importance.high,
    );
    const uploadChannel = AndroidNotificationChannel(
      'upload_alerts',
      'Upload Alerts',
      description: 'Lets you know when your data needs attention to reach the research server',
      importance: Importance.high,
    );
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(riskChannel);
    await androidPlugin?.createNotificationChannel(uploadChannel);

    if (Platform.isAndroid) {
      await androidPlugin?.requestNotificationsPermission();
    }

    print('[NotificationService] initialized');
  }

  static Future<void> sendRiskAlert(double score) async {
    if (score <= 0.87) return;

    final now = DateTime.now();
    final isHigh = score > 0.93;

    if (isHigh) {
      if (_lastHighAlert != null && now.difference(_lastHighAlert!) < _cooldown) return;
      _lastHighAlert = now;
    } else {
      if (_lastMedAlert != null && now.difference(_lastMedAlert!) < _cooldown) return;
      _lastMedAlert = now;
    }

    final title = isHigh ? 'High Risk Detected' : 'Elevated Risk';
    final body = isHigh
        ? 'Risk score ${(score * 100).toStringAsFixed(0)}% — check PulseWatch app'
        : 'Risk score ${(score * 100).toStringAsFixed(0)}% — monitor your condition';
    final importance = isHigh ? Importance.high : Importance.defaultImportance;
    final priority = isHigh ? Priority.high : Priority.defaultPriority;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'risk_alerts',
        'Risk Alerts',
        channelDescription: 'Cardiac risk alerts from PulseWatch AI',
        importance: importance,
        priority: priority,
        icon: '@mipmap/ic_launcher',
      ),
    );

    await _plugin.show(isHigh ? 1 : 2, title, body, details);
    print('[NotificationService] sent alert level=${isHigh ? "high" : "medium"} score=${score.toStringAsFixed(2)}');
  }

  /// Fires once, whenever the one-time 48h report finishes computing —
  /// unlike sendRiskAlert above (which only fires past a risk threshold,
  /// so most low/medium-risk sessions never notified anyone that their
  /// report was even ready). Body text deliberately says nothing about
  /// the actual risk level or score — that can sit in a lock-screen
  /// notification preview where anyone glancing at the phone would see it.
  static Future<void> sendReportReadyAlert() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'risk_alerts',
        'Risk Alerts',
        channelDescription: 'Cardiac risk alerts from PulseWatch AI',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    );
    await _plugin.show(
      5,
      'Your 48-hour report is ready',
      "You've completed your full session — open PulseWatch to see your results.",
      details,
    );
    print('[NotificationService] sent report-ready alert');
  }

  static Future<void> sendConnectivityAlert() async {
    if (!await _uploadCooldownElapsed('last_connectivity_alert_ms')) return;
    await _showUploadNotification(
      id: 3,
      title: 'No connection',
      body: "PulseWatch can't reach the research server. Connect to Wi-Fi "
          'or mobile data to keep your data backed up.',
    );
  }

  static Future<void> sendUploadBacklogAlert() async {
    if (!await _uploadCooldownElapsed('last_backlog_alert_ms')) return;
    await _showUploadNotification(
      id: 4,
      title: 'Your data needs uploading',
      body: "PulseWatch hasn't been able to reach the server in a while. "
          'Open the app to upload manually.',
    );
  }

  static Future<bool> _uploadCooldownElapsed(String prefKey) async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(prefKey);
    final now = DateTime.now();
    if (lastMs != null) {
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (now.difference(last) < _uploadAlertCooldown) return false;
    }
    await prefs.setInt(prefKey, now.millisecondsSinceEpoch);
    return true;
  }

  static Future<void> _showUploadNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'upload_alerts',
        'Upload Alerts',
        channelDescription: 'Lets you know when your data needs attention to reach the research server',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    );
    await _plugin.show(id, title, body, details);
    print('[NotificationService] sent upload alert id=$id title=$title');
  }
}
