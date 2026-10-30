import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System notifications for completed long-running tasks. Permission prompts
/// are requested lazily when the plugin is enabled.
class SystemNotifications {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _setupStarted = false;
  int _nextId = 0;

  Future<void> setup() async {
    if (kIsWeb || _setupStarted) return;
    _setupStarted = true;
    try {
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const settings = InitializationSettings(
        iOS: darwin,
        macOS: darwin,
        linux: LinuxInitializationSettings(defaultActionName: '打开 W Term'),
        windows: WindowsInitializationSettings(
          appName: 'W Term',
          appUserModelId: 'WuBarlynn.WTerm',
          guid: '9f12b2c4-7c6d-4b3a-8f1e-2d5a6c7b8e90',
        ),
      );
      await _plugin.initialize(settings: settings);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  Future<void> showTask({required String title, required String body}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: '任务完成 · $title',
        body: body,
        notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(presentAlert: true),
          macOS: DarwinNotificationDetails(presentAlert: true),
          windows: WindowsNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
      );
    } catch (_) {
      // A denied permission must not affect the terminal.
    }
  }
}

final systemNotifications = SystemNotifications();
