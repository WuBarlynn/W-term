import 'dart:io';

import 'package:flutter/services.dart';

/// iOS scene bridge. The token never leaves process memory and is only used by
/// additional iPad windows to share the already-unlocked vault connection.
class WindowBridge {
  static const _channel = MethodChannel('dev.wterm/windows');

  static bool get supported => Platform.isIOS;

  static Future<String?> sharedVaultToken() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('sharedVaultToken');
    } catch (_) {
      return null;
    }
  }

  static Future<void> retainVault(String token) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('retainVault', {'token': token});
    } catch (_) {
      // A missing bridge must not block the primary window.
    }
  }

  /// Returns true when the last sharing window released the vault.
  static Future<bool> releaseVault() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('releaseVault') ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> clearVault() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('clearVault');
    } catch (_) {}
  }

  static Future<bool> openNewWindow() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('newWindow') ?? false;
    } catch (_) {
      return false;
    }
  }
}
