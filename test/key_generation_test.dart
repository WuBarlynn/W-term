import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/identity_store.dart';
import 'package:wterm/features/identities_pane.dart';

class KeyLibrary implements IdentityStore, KeyStore {
  final items = <SavedIdentity>[];
  bool fail = false;
  int calls = 0;
  @override
  Future<List<SavedIdentity>> identities() async => List.of(items);
  @override
  Future<String> generateKey(String name, String username) async {
    calls++;
    if (fail) throw StateError('生成失败');
    items.add(
      SavedIdentity(id: 'new', name: name, username: username, kind: 'key'),
    );
    return 'new';
  }

  @override
  Future<String> publicKey(String id) async => 'ssh-ed25519 test-public-key';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> open(WidgetTester tester, KeyLibrary store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: IdentitiesPane(store: store)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('生成 SSH 密钥'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'validates generation, saves identity and copies only public key',
    (tester) async {
      final store = KeyLibrary();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await open(tester, store);
      await tester.tap(find.text('生成并保存'));
      await tester.pumpAndSettle();
      expect(store.calls, 0);
      expect(find.text('请输入用户名'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, '身份名称'),
        ' My Mac ',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '用户名'),
        ' root ',
      );
      await tester.tap(find.text('生成并保存'));
      await tester.pumpAndSettle();
      expect(store.items.single.name, 'My Mac');
      expect(store.items.single.username, 'root');
      expect(find.text('SSH 公钥'), findsOneWidget);
      await tester.tap(find.text('复制公钥'));
      await tester.pumpAndSettle();
      expect(copied, 'ssh-ed25519 test-public-key');
      expect(find.text('My Mac'), findsOneWidget);
      await tester.tap(find.byTooltip('身份操作：My Mac'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看 / 复制公钥'));
      await tester.pumpAndSettle();
      expect(find.text('SSH 公钥'), findsOneWidget);
    },
  );
  testWidgets('cancel does not create a key', (tester) async {
    final store = KeyLibrary();
    await open(tester, store);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.calls, 0);
  });
  testWidgets('generation failure remains visible and allows retry', (
    tester,
  ) async {
    final store = KeyLibrary()..fail = true;
    await open(tester, store);
    await tester.enterText(find.widgetWithText(TextFormField, '身份名称'), 'Mac');
    await tester.enterText(find.widgetWithText(TextFormField, '用户名'), 'root');
    await tester.tap(find.text('生成并保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('生成失败'), findsOneWidget);
    expect(store.items, isEmpty);
    await tester.tap(find.byTooltip('生成 SSH 密钥'));
    await tester.pumpAndSettle();
    expect(find.text('生成并保存'), findsOneWidget);
  });
}
