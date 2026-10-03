import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'engine_models.dart';

/// Shows an operating-system notification for an engine alert.
abstract class AlertNotifier {
  /// Asks the OS for permission (once). Returns whether notifications can be shown.
  Future<bool> ensurePermission();
  Future<void> show(EngineNotification n, {required String engineLabel});
}

/// Does nothing. Used in tests and on platforms without notification support.
class NoopAlertNotifier implements AlertNotifier {
  const NoopAlertNotifier();
  @override
  Future<bool> ensurePermission() async => false;
  @override
  Future<void> show(EngineNotification n, {required String engineLabel}) async {}
}

/// Records what would have been shown (tests).
class RecordingAlertNotifier implements AlertNotifier {
  final List<EngineNotification> shown = [];
  @override
  Future<bool> ensurePermission() async => true;
  @override
  Future<void> show(EngineNotification n, {required String engineLabel}) async => shown.add(n);
}

/// `flutter_local_notifications` backed notifier for iOS, Android and macOS.
/// Local only: nothing leaves the device, no push service is involved, so an
/// alert can only appear while the app is running and connected to the engine.
class LocalAlertNotifier implements AlertNotifier {
  LocalAlertNotifier({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  Future<bool>? _init;
  int _nextId = 1;

  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<bool> ensurePermission() => _init ??= _initialize();

  Future<bool> _initialize() async {
    if (!supported) return false;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
        ),
      );
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) return await android.requestNotificationsPermission() ?? false;
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) return await ios.requestPermissions(alert: true, sound: true, badge: true) ?? false;
      final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      if (mac != null) return await mac.requestPermissions(alert: true, sound: true, badge: true) ?? false;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> show(EngineNotification n, {required String engineLabel}) async {
    if (!await ensurePermission()) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: n.title.isEmpty ? 'Forge alert' : n.title,
        body: '${n.message}\n$engineLabel',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'forge_critical',
            'Critical Forge alerts',
            channelDescription: 'Quota, circuit and runaway-protection alerts from your Forge engine',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
          macOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
      );
    } catch (_) {
      // A notification failing must never affect the app.
    }
  }
}
