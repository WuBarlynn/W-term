import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// iOS uses biometric Keychain access; macOS uses a Secure Enclave protected
/// envelope, which also works with a stable self-signed application identity.
class QuickUnlock {
  static const _channel = MethodChannel('dev.wterm/biometrics');
  static const _key = 'vault-master-v1';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'dev.wterm.biometric-vault',
      accessibility: KeychainAccessibility.unlocked_this_device,
      accessControlFlags: [AccessControlFlag.biometryCurrentSet],
    ),
  );

  Future<T?> _invokeMac<T>(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw QuickUnlockException(error.message ?? 'Touch ID 未完成，请重试或使用主密码解锁');
    }
  }

  Future<String?> availableType() async {
    try {
      return await _channel.invokeMethod<String>('availableType');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<File> _marker() async => File(
    '${(await getApplicationSupportDirectory()).path}/biometric-unlock.enabled',
  );
  Future<bool> enabled() async {
    if (Platform.isMacOS) {
      return await _invokeMac<bool>('quickUnlockEnabled') ?? false;
    }
    return (await _marker()).exists();
  }

  Future<void> enroll(String password) async {
    if (await availableType() == null) {
      throw StateError('设备未设置可用的 Touch ID 或 Face ID');
    }
    if (Platform.isMacOS) {
      await _invokeMac<void>('quickUnlockEnroll', {'password': password});
      return;
    }
    try {
      // Replace any invalidated enrollment rather than updating its old ACL.
      await disable();
      await _storage.write(key: _key, value: password);
    } on PlatformException catch (e) {
      if ('${e.code} ${e.message}'.contains('-34018')) {
        throw StateError(
          '系统拒绝受保护钥匙串访问（-34018）。签名通过预检不代表拥有系统钥匙串权限，请检查此签名版本的权限配置；仍可使用主密码解锁',
        );
      }
      throw StateError('系统钥匙串无法保存快速解锁凭证（${e.code}）。请检查生物识别设置；仍可使用主密码解锁');
    }
    final marker = await _marker();
    await marker.parent.create(recursive: true);
    await marker.writeAsString('1', flush: true);
  }

  Future<String> read() async {
    final secret = Platform.isMacOS
        ? await _invokeMac<String>('quickUnlockRead')
        : await _storage.read(key: _key);
    if (secret == null || secret.isEmpty) {
      throw StateError('快速解锁已失效，请使用主密码解锁并重新启用');
    }
    return secret;
  }

  Future<void> disable() async {
    if (Platform.isMacOS) {
      await _invokeMac<void>('quickUnlockDisable');
      return;
    }
    await _storage.delete(key: _key);
    final marker = await _marker();
    if (await marker.exists()) await marker.delete();
  }
}

class QuickUnlockException implements Exception {
  final String message;
  const QuickUnlockException(this.message);
  @override
  String toString() => message;
}
