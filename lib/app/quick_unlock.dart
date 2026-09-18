import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// The marker is only a preference. Keychain enforces biometric access to the
/// secret itself; no authentication success boolean can bypass that protection.
class QuickUnlock {
  static const _channel = MethodChannel('dev.wterm/biometrics');
  static const _key = 'vault-master-v1';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'dev.wterm.biometric-vault',
      accessibility: KeychainAccessibility.unlocked_this_device,
      accessControlFlags: [AccessControlFlag.biometryCurrentSet],
    ),
    mOptions: MacOsOptions(
      accountName: 'dev.wterm.biometric-vault',
      usesDataProtectionKeychain: true,
      accessibility: KeychainAccessibility.unlocked_this_device,
      accessControlFlags: [AccessControlFlag.biometryCurrentSet],
    ),
  );

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
  Future<bool> enabled() async => (await _marker()).exists();
  Future<void> enroll(String password) async {
    if (await availableType() == null) {
      throw StateError('设备未设置可用的 Touch ID 或 Face ID');
    }
    if (Platform.isMacOS) {
      final issue = await _channel.invokeMethod<String>('keychainAccessIssue');
      if (issue != null) throw StateError(issue);
    }
    // Replace any invalidated enrollment rather than updating its old ACL.
    await disable();
    try {
      await _storage.write(key: _key, value: password);
    } on PlatformException catch (e) {
      if ('${e.code} ${e.message}'.contains('-34018')) {
        throw StateError(
          '系统拒绝钥匙串访问（-34018）：应用签名缺少 Keychain 权限，请配置 Apple 签名后重试',
        );
      }
      throw StateError('系统钥匙串无法保存快速解锁凭证（${e.code}）。请检查生物识别设置；仍可使用主密码解锁');
    }
    final marker = await _marker();
    await marker.parent.create(recursive: true);
    await marker.writeAsString('1', flush: true);
  }

  Future<String> read() async {
    final secret = await _storage.read(key: _key);
    if (secret == null || secret.isEmpty) {
      throw StateError('快速解锁已失效，请使用主密码解锁并重新启用');
    }
    return secret;
  }

  Future<void> disable() async {
    await _storage.delete(key: _key);
    final marker = await _marker();
    if (await marker.exists()) await marker.delete();
  }
}
