import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'desktop_tray.dart';

/// A single system-wide shortcut that focuses the main window. Disabled by
/// default because global shortcuts can collide with other applications.
class DesktopHotkey {
  HotKey? _registered;

  bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  String get label => Platform.isMacOS ? '⌘ + ⇧ + Space' : 'Ctrl + Alt + Space';

  Future<bool> setup(bool enabled) async {
    if (!supported) return false;
    final previous = _registered;
    if (previous != null) {
      _registered = null;
      try {
        await hotKeyManager.unregister(previous);
      } catch (_) {}
    }
    if (!enabled) return true;
    final hotKey = HotKey(
      identifier: 'wterm.show-window',
      key: LogicalKeyboardKey.space,
      modifiers: Platform.isMacOS
          ? const [HotKeyModifier.meta, HotKeyModifier.shift]
          : const [HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => desktopTray.showWindow(),
      );
      _registered = hotKey;
      return true;
    } catch (_) {
      return false;
    }
  }
}

final desktopHotkey = DesktopHotkey();
