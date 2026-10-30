import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_store.dart';
import 'package:wterm/app/identity_store.dart';
import 'package:wterm/features/hosts_page.dart';
import 'package:wterm/features/host_editor.dart';
import 'package:wterm/features/identities_pane.dart';

class MemoryLibrary
    implements HostStore, FolderStore, FolderTreeStore, IdentityStore {
  List<HostProfile> hosts = [];
  List<String> folders = [];
  List<SavedIdentity> saved = [];
  String? capturedPassword;
  @override
  Future<List<HostProfile>> read() async => [...hosts];
  @override
  Future<void> write(List<HostProfile> h) async {
    hosts = [...h];
  }

  @override
  Future<List<String>> readFolders() async => [...folders];
  @override
  Future<void> writeFolders(List<String> f) async {
    folders = [...f];
  }

  @override
  Future<String> renameFolder(String path, String name) async {
    final parts = path.split('/')..removeLast();
    final destination = [...parts, name].join('/');
    String renamed(String value) => value == path || value.startsWith('$path/')
        ? '$destination${value.substring(path.length)}'
        : value;
    folders = folders.map(renamed).toList();
    hosts = hosts
        .map(
          (h) =>
              HostProfile.fromJson({...h.toJson(), 'group': renamed(h.group)}),
        )
        .toList();
    return destination;
  }

  @override
  Future<void> deleteFolder(String path, {bool deleteHosts = false}) async {
    bool within(String p) => p == path || p.startsWith('$path/');
    folders.removeWhere(within);
    if (deleteHosts) hosts.removeWhere((h) => within(h.group));
    hosts = hosts
        .map(
          (h) => HostProfile.fromJson({
            ...h.toJson(),
            'group': within(h.group) ? '' : h.group,
          }),
        )
        .toList();
  }

  @override
  Future<List<SavedIdentity>> identities() async => [...saved];
  @override
  Future<String> saveIdentity(IdentityDraft d) async {
    final id = d.id.isEmpty ? 'identity-${saved.length}' : d.id;
    capturedPassword = d.password;
    saved.removeWhere((i) => i.id == id);
    saved.add(
      SavedIdentity(id: id, name: d.name, username: d.username, kind: d.kind),
    );
    d.clear();
    return id;
  }

  @override
  Future<void> deleteIdentity(String id) async {
    if (hosts.any((h) => h.identityId == id)) throw StateError('此身份仍被主机使用');
    saved.removeWhere((i) => i.id == id);
  }

  @override
  Future<HostProfile> saveHost(HostProfile h, IdentityDraft? d) async {
    final id = d == null ? h.identityId : await saveIdentity(d);
    final result = HostProfile.fromJson({...h.toJson(), 'identityId': id});
    hosts.removeWhere((v) => v.id == h.id);
    hosts.add(result);
    return result;
  }

  @override
  Future<String> authenticateIdentity(
    String identityId,
    String connectionId,
    String fingerprint,
  ) async => saved.firstWhere((i) => i.id == identityId).username;

  @override
  Future<String> authenticateJumpIdentity(
    String identityId,
    String connectionId,
    String fingerprint,
  ) async => saved.firstWhere((i) => i.id == identityId).username;
}

void main() {
  testWidgets(
    'single click is inert, double click connects, menu edits without connecting',
    (tester) async {
      final store = MemoryLibrary()
        ..hosts = [
          HostProfile(
            id: 'a',
            name: 'Saved host',
            host: 'example.com',
            username: 'alice',
            identityId: 'i',
          ),
        ]
        ..saved = [
          const SavedIdentity(
            id: 'i',
            name: 'Work key',
            username: 'alice',
            kind: 'key',
          ),
        ];
      var connections = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: HostsPage(store: store, onConnect: (_) => connections++),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved host'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(connections, 0);
      await tester.tap(find.text('Saved host'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('Saved host'));
      await tester.pumpAndSettle();
      expect(connections, 1);
      await tester.tap(find.byTooltip('主机操作：Saved host'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('编辑主机'), findsOneWidget);
      expect(find.text('新建 SSH 连接'), findsNothing);
      await tester.enterText(find.byType(TextFormField).first, 'Renamed');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(store.hosts.single.identityId, 'i');
      expect(store.hosts.single.name, 'Renamed');
      expect(connections, 1);
    },
  );
  testWidgets('new host saves credentials and host association together', (
    tester,
  ) async {
    final store = MemoryLibrary();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showDialog<HostProfile>(
                context: c,
                builder: (_) => HostEditor(credentials: store),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    for (final e in {
      0: 'Server',
      1: 'example.com',
      3: 'alice',
      8: 'fixture-password',
    }.entries) {
      await tester.enterText(fields.at(e.key), e.value);
    }
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(store.hosts.single.identityId, isNotEmpty);
    expect(store.capturedPassword, 'fixture-password');
    expect(store.hosts.single.toJson().containsKey('password'), isFalse);
  });
  testWidgets('nested folders collapse recursively and delete keeps hosts', (
    tester,
  ) async {
    final store = MemoryLibrary()
      ..folders = ['Work', 'Work/Prod']
      ..hosts = [
        HostProfile(
          id: 'a',
          name: 'API',
          host: 'h',
          username: 'u',
          group: 'Work/Prod',
        ),
      ];
    await tester.pumpWidget(MaterialApp(home: HostsPage(store: store)));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('API')).dx,
      greaterThan(tester.getTopLeft(find.text('Prod')).dx),
    );
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(find.text('Prod'), findsNothing);
    expect(find.text('API'), findsNothing);
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件夹操作：Work/Prod'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建子文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'EU');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(store.folders, contains('Work/Prod/EU'));
    expect(find.text('EU'), findsOneWidget);
    await tester.tap(find.byTooltip('文件夹操作：Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '保留主机到未分类'));
    await tester.pumpAndSettle();
    expect(store.folders, isEmpty);
    expect(store.hosts.single.group, '');
    expect(find.text('API'), findsOneWidget);
    expect(find.text('未分类'), findsOneWidget);
  });
  testWidgets('delete folder and all nested hosts preserves neighbors', (
    tester,
  ) async {
    final store = MemoryLibrary()
      ..folders = ['Work', 'Work/Sub', 'Work2']
      ..hosts = [
        HostProfile(
          id: 'a',
          name: 'Inside',
          host: 'h',
          username: 'u',
          group: 'Work/Sub',
        ),
        HostProfile(
          id: 'b',
          name: 'Outside',
          host: 'h',
          username: 'u',
          group: 'Work2',
        ),
      ];
    await tester.pumpWidget(MaterialApp(home: HostsPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件夹操作：Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除文件夹及全部主机'));
    await tester.pumpAndSettle();
    expect(store.folders, ['Work2']);
    expect(store.hosts.single.name, 'Outside');
    expect(find.text('Inside'), findsNothing);
  });
  testWidgets(
    'renaming a collapsed folder preserves collapse and host identity',
    (tester) async {
      final store = MemoryLibrary()
        ..folders = ['Work', 'Work/Sub']
        ..hosts = [
          HostProfile(
            id: 'h',
            name: 'Server',
            host: 'host',
            username: 'u',
            group: 'Work/Sub',
            identityId: 'identity',
          ),
        ];
      await tester.pumpWidget(MaterialApp(home: HostsPage(store: store)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文件夹操作：Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Production');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('Server'), findsNothing);
      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(find.text('Server'), findsOneWidget);
      expect(store.hosts.single.group, 'Production/Sub');
      expect(store.hosts.single.identityId, 'identity');
    },
  );
  testWidgets('host hover and click selection highlight without connecting', (
    tester,
  ) async {
    final store = MemoryLibrary()
      ..hosts = [
        HostProfile(id: 'a', name: 'Alpha', host: 'a', username: 'u'),
        HostProfile(id: 'b', name: 'Beta', host: 'b', username: 'u'),
      ];
    var connections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HostsPage(store: store, onConnect: (_) => connections++),
      ),
    );
    await tester.pumpAndSettle();
    Color? color(String id) =>
        tester.widget<Material>(find.byKey(ValueKey('host-row-$id'))).color;
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(find.text('Alpha')));
    await tester.pumpAndSettle();
    expect(color('a'), isNot(Colors.transparent));
    await pointer.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(color('a'), Colors.transparent);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(color('a'), isNot(Colors.transparent));
    expect(connections, 0);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(color('a'), Colors.transparent);
    expect(color('b'), isNot(Colors.transparent));
    expect(connections, 0);
  });
  testWidgets('interactive-only identity saves no secrets', (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    IdentityDraft? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                captured = await showDialog<IdentityDraft>(
                  context: context,
                  builder: (_) => const IdentityEditor(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅交互式'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '身份名称'),
      'MFA only',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '用户名'),
      'mfa-user',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(captured?.kind, 'interactive');
    expect(captured?.password, isEmpty);
    expect(captured?.privateKey, isEmpty);
    expect(captured?.passphrase, isEmpty);
  });
  testWidgets(
    'identity editor preserves saved secrets unless replacement is selected',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: IdentityEditor(
              identity: SavedIdentity(
                id: 'a',
                name: 'Key',
                username: 'alice',
                kind: 'key',
              ),
            ),
          ),
        ),
      );
      expect(find.text('替换保存的凭证'), findsOneWidget);
      expect(find.text('私钥内容'), findsNothing);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(find.text('私钥内容'), findsOneWidget);
    },
  );
}
