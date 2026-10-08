import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/quick_unlock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.wterm/biometrics');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const oldKey = 'vault-master-v1';
  final calls = <MethodCall>[];
  String? saved;
  String? nativeFailure;

  setUp(() {
    calls.clear();
    saved = null;
    nativeFailure = null;
    // The obsolete macOS Keychain record must never be used as a fallback.
    FlutterSecureStorage.setMockInitialValues({oldKey: 'old-keychain-secret'});
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'availableType') return 'Touch ID';
      if (nativeFailure != null) {
        throw PlatformException(
          code: 'quick_unlock_failed',
          message: nativeFailure,
        );
      }
      switch (call.method) {
        case 'quickUnlockEnabled':
          return saved != null;
        case 'quickUnlockEnroll':
          saved = (call.arguments as Map)['password'] as String;
          return null;
        case 'quickUnlockRead':
          return saved;
        case 'quickUnlockDisable':
          saved = null;
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('macOS hardware-backed quick unlock', () {
    test(
      'enroll read disable use native storage without old Keychain or marker',
      () async {
        final quick = QuickUnlock();
        expect(await quick.enabled(), isFalse);
        await quick.enroll('new-test-secret');
        expect(await quick.enabled(), isTrue);
        expect(await quick.read(), 'new-test-secret');
        await quick.disable();
        expect(await quick.enabled(), isFalse);
        expect(
          await const FlutterSecureStorage().read(key: oldKey),
          'old-keychain-secret',
        );
        expect(calls.map((call) => call.method), [
          'quickUnlockEnabled',
          'availableType',
          'quickUnlockEnroll',
          'quickUnlockEnabled',
          'quickUnlockRead',
          'quickUnlockDisable',
          'quickUnlockEnabled',
        ]);
      },
    );

    test(
      'native cancellation preserves existing enrollment and readable error',
      () async {
        saved = 'previous-test-secret';
        nativeFailure = 'Touch ID 已取消';
        await expectLater(
          QuickUnlock().enroll('replacement'),
          throwsA(
            isA<QuickUnlockException>().having(
              (e) => e.toString(),
              'message',
              'Touch ID 已取消',
            ),
          ),
        );
        expect(saved, 'previous-test-secret');
        expect(
          calls.any((call) => call.method == 'quickUnlockDisable'),
          isFalse,
        );
      },
    );

    test(
      'native signature rejection does not fall back to legacy Keychain',
      () async {
        nativeFailure = 'ad-hoc 签名不能使用 Touch ID';
        await expectLater(
          QuickUnlock().read(),
          throwsA(isA<QuickUnlockException>()),
        );
      },
    );

    test('absent enrollment never reads the old Keychain secret', () async {
      await expectLater(QuickUnlock().read(), throwsStateError);
    });

    test('missing native implementation fails closed', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw MissingPluginException(),
      );
      await expectLater(
        QuickUnlock().read(),
        throwsA(isA<MissingPluginException>()),
      );
    });
  }, skip: !Platform.isMacOS);
}
