import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/proxy_store.dart';
import 'package:wterm/features/proxy_dialog.dart';
import 'package:wterm/features/proxy_profile_editor.dart';
import 'package:wterm/src/rust/api/client.dart';
import 'package:wterm/src/rust/api/proxy.dart';

class Store implements ConnectionProxyStore {
  ProxySettings current = const ProxySettings(
    mode: 'http',
    host: 'proxy.example',
    port: 3128,
    authenticate: true,
    username: 'alice',
    passwordSaved: true,
  );
  ProxySettings? submitted;
  String? password;
  List<ProxyProfile> items = [];
  bool failRead = false, failSave = false;
  @override
  Future<ProxySettings> proxySettings() async {
    if (failRead) throw StateError('读取失败');
    return current;
  }

  @override
  Future<void> saveProxySettings(ProxySettings settings, String secret) async {
    if (failSave) throw StateError('保存失败');
    submitted = settings;
    password = secret;
  }

  @override
  Future<List<ProxyProfile>> proxyProfiles() async => items;
  @override
  Future<String> saveProxyProfile(
    ProxyProfileInput profile,
    String secret,
  ) async {
    final saved = ProxyProfile(
      id: profile.id.isEmpty ? 'p1' : profile.id,
      name: profile.name,
      mode: profile.mode,
      host: profile.host,
      port: profile.port,
      authenticate: profile.authenticate,
      username: profile.username,
      passwordSaved: profile.authenticate,
    );
    items = [...items.where((p) => p.id != saved.id), saved];
    return saved.id;
  }

  @override
  Future<void> deleteProxyProfile(String id) async {
    items = items.where((p) => p.id != id).toList();
  }

  @override
  Future<String> hostProxyBinding(String hostId) async => '';
  @override
  Future<void> setHostProxyBinding(String hostId, String binding) async {}
  @override
  Future<ProxyTestResult> testProxyGlobal(
    String targetHost,
    int targetPort,
  ) async => const ProxyTestResult(
    tcpOk: true,
    authenticated: true,
    targetOk: null,
    message: '代理 TCP 可达',
  );
  @override
  Future<ProxyTestResult> testProxyProfile(
    String id,
    String targetHost,
    int targetPort,
  ) async => const ProxyTestResult(
    tcpOk: true,
    authenticated: true,
    targetOk: true,
    message: '目标可以连接',
  );
  @override
  Future<ProxyTestResult> testProxyDraft(
    ProxyDraft draft,
    String password,
    String targetHost,
    int targetPort,
  ) async => const ProxyTestResult(
    tcpOk: true,
    authenticated: true,
    targetOk: true,
    message: '目标可以连接',
  );

  @override
  Future<ServerIdentity> probeWithProxy(
    String host,
    int port, {
    String operationId = '',
  }) => throw UnimplementedError();

  @override
  Future<ServerIdentity> probeWithHostProxy(
    String hostId,
    String host,
    int port, {
    String operationId = '',
  }) => throw UnimplementedError();

  @override
  Future<ServerIdentity> probeThrough(
    String parentConnectionId,
    String host,
    int port, {
    String operationId = '',
  }) => throw UnimplementedError();

  @override
  Future<void> cancelProbe(String operationId) async {}
}

Future<void> open(WidgetTester t, Store store) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ProxyDialog(store: store),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

Finder field(String label) => find.widgetWithText(TextFormField, label);
Finder editorField(String label) => find.descendant(
  of: find.byType(ProxyProfileEditor),
  matching: find.widgetWithText(TextFormField, label),
);
Future<void> choose(WidgetTester t, String label) async {
  await t.ensureVisible(find.byType(DropdownButtonFormField<String>));
  await t.tap(find.byType(DropdownButtonFormField<String>));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('saved proxy password stays masked and blank retains it', (
    t,
  ) async {
    final store = Store();
    await open(t, store);
    final input = t.widget<TextFormField>(field('代理密码'));
    expect(input.controller!.text, isEmpty);
    expect(find.text('已加密保存，留空保留原密码'), findsOneWidget);
    final passwordField = t.widget<TextField>(
      find.descendant(of: field('代理密码'), matching: find.byType(TextField)),
    );
    expect(passwordField.obscureText, isTrue);
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(store.submitted!.host, 'proxy.example');
    expect(store.password, '');
    expect(find.byType(ProxyDialog), findsNothing);
  });
  testWidgets(
    'changing endpoint requires fresh credentials and failure clears typed password',
    (t) async {
      final store = Store();
      await open(t, store);
      await t.enterText(field('代理地址'), 'different.example');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.submitted, isNull);
      expect(find.text('请输入代理密码'), findsOneWidget);
      await t.ensureVisible(field('代理密码'));
      await t.enterText(field('代理密码'), 'replacement-secret');
      store.failSave = true;
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(t.widget<TextFormField>(field('代理密码')).controller!.text, isEmpty);
      expect(find.textContaining('保存失败'), findsOneWidget);
      store.failSave = false;
      await t.enterText(field('代理密码'), 'replacement-secret');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.submitted!.host, 'different.example');
      expect(store.password, 'replacement-secret');
    },
  );
  testWidgets(
    'cancel preserves configuration while explicit direct clears it',
    (t) async {
      final store = Store();
      await open(t, store);
      await choose(t, '直接连接');
      expect(find.text('保存后清除本机代理配置及其密码。'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(store.submitted, isNull);
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await choose(t, '直接连接');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.submitted!.mode, 'direct');
      expect(store.password, '');
    },
  );
  testWidgets(
    'compact screen scrolls with keyboard and can save unauthenticated proxy',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetViewInsets);
      final store = Store();
      await open(t, store);
      await t.ensureVisible(find.byType(SwitchListTile));
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.submitted!.authenticate, isFalse);
      expect(store.submitted!.username, isEmpty);
      expect(store.password, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'read failure cannot silently save defaults and has explicit reset',
    (t) async {
      final store = Store()..failRead = true;
      await open(t, store);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(store.submitted, isNull);
      await t.tap(find.text('清除代理并恢复直连'));
      await t.pumpAndSettle();
      expect(store.submitted!.mode, 'direct');
    },
  );
  testWidgets('named profile lists, menu test and layered result stages', (
    t,
  ) async {
    final store = Store()
      ..items = [
        const ProxyProfile(
          id: 'p1',
          name: 'Corp',
          mode: 'socks5',
          host: '10.0.0.1',
          port: 1080,
          authenticate: false,
          username: '',
          passwordSaved: false,
        ),
      ];
    await open(t, store);
    await t.ensureVisible(find.text('Corp'));
    expect(find.textContaining('SOCKS5 · 10.0.0.1:1080'), findsOneWidget);
    await t.tap(find.byTooltip('代理操作：Corp'));
    await t.pumpAndSettle();
    await t.tap(find.text('测试'));
    await t.pumpAndSettle();
    expect(find.text('测试代理：Corp'), findsOneWidget);
    await t.enterText(
      find.widgetWithText(TextField, '目标主机（可选）'),
      'internal.example',
    );
    await t.enterText(find.widgetWithText(TextField, '端口'), '22');
    await t.tap(find.text('开始测试'));
    await t.pumpAndSettle();
    expect(find.text('代理 TCP 可达：通过'), findsOneWidget);
    expect(find.text('代理认证通过：通过'), findsOneWidget);
    expect(find.text('目标可达（TCP）：通过'), findsOneWidget);
    expect(find.text('目标可以连接'), findsOneWidget);
    await t.tap(find.text('关闭').last);
    await t.pumpAndSettle();
    expect(find.byType(ProxyDialog), findsOneWidget);
  });
  testWidgets('adds a named profile and keeps the dialog open', (t) async {
    final store = Store();
    await open(t, store);
    await t.ensureVisible(find.text('添加'));
    await t.tap(find.text('添加'));
    await t.pumpAndSettle();
    expect(find.text('添加命名代理'), findsOneWidget);
    await t.enterText(editorField('代理名称'), 'Office');
    await t.enterText(editorField('代理地址'), 'office.example');
    await t.enterText(editorField('代理端口'), '8080');
    await t.ensureVisible(find.text('保存').last);
    await t.tap(find.text('保存').last);
    await t.pumpAndSettle();
    expect(store.items.single.name, 'Office');
    expect(find.text('Office'), findsOneWidget);
    expect(find.byType(ProxyDialog), findsOneWidget);
  });
}
