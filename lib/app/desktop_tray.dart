import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Requests a new connection after the tray menu asks the workspace to focus.
final trayConnectRequests = ValueNotifier<int>(0);

class DesktopTray with TrayListener {
  bool _ready = false;

  bool get _supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> setup() async {
    if (!_supported) return;
    try {
      await windowManager.ensureInitialized();
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/icon/wterm.ico'
            : 'assets/icon/wterm-icon-1024.png',
        isTemplate: false,
      );
      await trayManager.setToolTip('W Term');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示 W Term', onClick: _clicked),
            MenuItem(key: 'new', label: '新建连接', onClick: _clicked),
            if (Platform.isMacOS || Platform.isWindows)
              MenuItem(
                key: 'shortcut',
                label: Platform.isMacOS
                    ? '显示快捷键：⌘ ⇧ Space'
                    : '显示快捷键：Ctrl + Alt + Space',
                disabled: true,
              ),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: '退出 W Term', onClick: _clicked),
          ],
        ),
      );
      trayManager.addListener(this);
      _ready = true;
    } catch (_) {
      // Tray support is optional; macOS may hide icons without permission.
    }
  }

  Future<void> showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // A window manager plugin may not be available in a detached engine.
    }
  }

  void _clicked(MenuItem item) {
    switch (item.key) {
      case 'show':
        showWindow();
      case 'new':
        showWindow();
        trayConnectRequests.value++;
      case 'quit':
        quit();
    }
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) => _clicked(menuItem);

  Future<void> quit() async {
    if (_ready) {
      _ready = false;
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
    exit(0);
  }
}

final desktopTray = DesktopTray();
