import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_store.dart';
import 'package:wterm/app/quick_unlock.dart';
import 'package:wterm/app/vault_store.dart';
import 'package:wterm/features/vault_gate.dart';

class FakeVault implements VaultSession {
  @override
  bool legacyImported = false;
  bool locked = false;
  List<HostProfile> hosts = [];
  List<String> folders = [];
  @override
  Future<void> importLegacy(List<HostProfile> h, List<String> f) async {
    hosts = h;
    folders = f;
    legacyImported = true;
  }

  @override
  Future<void> lock() async {
    locked = true;
  }

  @override
  Future<List<HostProfile>> read() async => hosts;
  @override
  Future<void> write(List<HostProfile> h) async {
    hosts = h;
  }

  @override
  Future<List<String>> readFolders() async => folders;
  @override
  Future<void> writeFolders(List<String> f) async {
    folders = f;
  }
}

class FakeService implements VaultService {
  bool hasVault = false, fail = false;
  final vault = FakeVault();
  Completer<VaultSession>? pending;
  final modes = <bool>[];
  @override
  Future<bool> exists() async => hasVault;
  @override
  Future<VaultSession> open(String password, {required bool create}) async {
    modes.add(create);
    if (fail) throw StateError('主密码错误');
    hasVault = true;
    vault.locked = false;
    return pending == null ? vault : pending!.future;
  }
}

class FakeQuickUnlock extends QuickUnlock {
  bool active = true, cancel = false;
  int reads = 0;
  String? saved;
  @override
  Future<String?> availableType() async => 'Face ID';
  @override
  Future<bool> enabled() async => active;
  @override
  Future<String> read() async {
    reads++;
    if (cancel) throw StateError('已取消面容识别');
    return 'test master password';
  }

  @override
  Future<void> enroll(String password) async {
    saved = password;
    active = true;
  }

  @override
  Future<void> disable() async {
    active = false;
  }
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.wterm/biometrics'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.wterm/biometrics'),
          null,
        );
  });
  Future<void> fill(WidgetTester tester, {bool create = true}) async {
    await tester.enterText(
      find.byType(TextFormField).first,
      'test master password',
    );
    if (create) {
      await tester.enterText(
        find.byType(TextFormField).last,
        'test master password',
      );
    }
    await tester.tap(find.text(create ? '创建并导入' : '解锁'));
  }

  testWidgets(
    'creation imports legacy records once, locking clears workspace and passwords',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final old = KeychainHostStore();
      await old.write([
        HostProfile(
          id: 'a',
          name: 'Private host',
          host: 'internal',
          username: 'user',
        ),
      ]);
      await old.writeFolders(['Work']);
      final service = FakeService();
      await tester.pumpWidget(
        MaterialApp(
          home: VaultGate(service: service, legacyStore: old),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建并导入'));
      await tester.pumpAndSettle();
      expect(find.text('请输入主密码'), findsOneWidget);
      await fill(tester);
      await tester.pumpAndSettle();
      expect(find.text('Private host'), findsOneWidget);
      expect(service.vault.folders, ['Work']);
      expect((await old.read()).length, 1);
      await tester.tap(find.text('锁定保险库'));
      await tester.pumpAndSettle();
      expect(service.vault.locked, isTrue);
      expect(find.text('Private host'), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        isEmpty,
      );
      await old.write([]);
      await fill(tester, create: false);
      await tester.pumpAndSettle();
      expect(find.text('Private host'), findsOneWidget);
      expect(service.modes, [true, false]);
    },
  );
  testWidgets(
    'failed migration retains old data and retries opening without overwriting vault',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        KeychainHostStore.key: 'broken',
      });
      final service = FakeService();
      await tester.pumpWidget(MaterialApp(home: VaultGate(service: service)));
      await tester.pumpAndSettle();
      await fill(tester);
      await tester.pumpAndSettle();
      expect(service.vault.locked, isTrue);
      expect(service.vault.legacyImported, isFalse);
      expect(find.text('解锁保险库'), findsOneWidget);
      expect(
        await const FlutterSecureStorage().read(key: KeychainHostStore.key),
        'broken',
      );
      service.fail = true;
      await fill(tester, create: false);
      await tester.pumpAndSettle();
      expect(find.textContaining('主密码错误'), findsOneWidget);
      expect(service.modes, [true, false]);
    },
  );
  testWidgets(
    'background during unlock preserves session behind privacy shield',
    (tester) async {
      final service = FakeService()
        ..hasVault = true
        ..pending = Completer<VaultSession>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: VaultGate(service: service),
        ),
      );
      await tester.pumpAndSettle();
      await fill(tester, create: false);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      service.pending!.complete(service.vault);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.vault.locked, isFalse);
      expect(vaultPrivacy.value, isFalse);
      expect(find.text('解锁保险库'), findsNothing);
      expect(service.modes, [false]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(service.vault.locked, isTrue);
    },
  );
  testWidgets(
    'biometric unlock bypasses password form and does not repeat on resume',
    (tester) async {
      final service = FakeService()..hasVault = true;
      final quick = FakeQuickUnlock();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: VaultGate(service: service, quickUnlock: quick),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用 Face ID 解锁'));
      await tester.pumpAndSettle();
      expect(service.modes, [false]);
      expect(quick.reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(vaultPrivacy.value, isTrue);
      expect(service.vault.locked, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(quick.reads, 1);
      expect(vaultPrivacy.value, isFalse);
    },
  );
  testWidgets('cancelled biometrics retains master password fallback', (
    tester,
  ) async {
    final service = FakeService()..hasVault = true;
    final quick = FakeQuickUnlock()..cancel = true;
    await tester.pumpWidget(
      MaterialApp(
        home: VaultGate(service: service, quickUnlock: quick),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用 Face ID 解锁'));
    await tester.pumpAndSettle();
    expect(service.modes, isEmpty);
    await fill(tester, create: false);
    await tester.pumpAndSettle();
    expect(service.modes, [false]);
    expect(service.vault.locked, isFalse);
  });
}
