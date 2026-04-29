import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static DateTime? _lastHighAlert;
  static DateTime? _lastMedAlert;
  static const _cooldown = Duration(minutes: 5);

  static Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings);

    const channel = AndroidNotificationChannel(
      'risk_alerts',
      'Risk Alerts',
      description: 'Cardiac risk alerts from PulseWatch AI',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    print('[NotificationService] initialized');
  }

  static Future<void> sendRiskAlert(double score) async {
    if (score <= 0.5) return;

    final now = DateTime.now();
    final isHigh = score > 0.75;

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
}
