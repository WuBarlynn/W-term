import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_store.dart';
import 'package:wterm/app/workspace.dart';
import 'package:wterm/app/snippet_store.dart';

class OfflineSnippetStore extends KeychainHostStore implements SnippetStore {
  @override
  Future<List<CommandSnippet>> readSnippets() async => [
    const CommandSnippet('1', 'Offline command', 'uptime'),
  ];
  @override
  Future<void> saveSnippet(String id, String name, String command) async {}
  @override
  Future<void> deleteSnippet(String id) async {}
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final width in [390.0, 1000.0]) {
    testWidgets('offline snippet sidebar works at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: Workspace(hostStore: OfflineSnippetStore())),
      );
      await tester.pumpAndSettle();
      if (width < 600) {
        await tester.tap(find.byTooltip('主机管理'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('命令片段'));
      await tester.pumpAndSettle();
      expect(find.text('Offline command'), findsOneWidget);
      await tester.tap(find.text('Offline command'));
      await tester.pumpAndSettle();
      expect(find.text('编辑片段'), findsOneWidget);
      expect(find.text('插入，不执行'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'desktop embeds folders at left and a compact session strip at right',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = KeychainHostStore();
      await store.write([
        HostProfile(
          id: 'a',
          name: 'API Server',
          host: 'example.com',
          username: 'alice',
          group: 'Production',
          tags: ['api'],
        ),
      ]);
      await tester.pumpWidget(MaterialApp(home: Workspace(hostStore: store)));
      await tester.pumpAndSettle();
      expect(find.text('Production'), findsOneWidget);
      expect(find.text('API Server'), findsOneWidget);
      final strip = find.byKey(const ValueKey('session-bar'));
      expect(tester.getSize(strip).height, 36);
      expect(tester.getTopLeft(strip).dx, greaterThanOrEqualTo(272));
      expect(tester.getTopLeft(find.text('API Server')).dx, lessThan(272));
      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(find.text('API Server'), findsNothing);
      await tester.enterText(find.byType(TextField), 'api');
      await tester.pumpAndSettle();
      expect(find.text('API Server'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建文件夹'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Personal');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(await KeychainHostStore().readFolders(), ['Personal']);
      expect(find.text('Personal'), findsOneWidget);
      await tester.tap(find.byTooltip('文件夹操作：Personal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加主机'));
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .toList();
      expect(fields[4].controller!.text, 'Personal');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'phone opens host drawer and selecting a host opens credentials',
    (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = KeychainHostStore();
      await store.write([
        HostProfile(
          id: 'a',
          name: 'Home',
          host: 'example.com',
          username: 'alice',
        ),
      ]);
      await tester.pumpWidget(MaterialApp(home: Workspace(hostStore: store)));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsNothing);
      await tester.tap(find.byTooltip('主机管理'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('连接 Home'), findsNothing);
      await tester.tap(find.text('Home'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('连接 Home'), findsOneWidget);
      expect(
        tester
            .widgetList<TextFormField>(find.byType(TextFormField))
            .map((f) => f.controller!.text),
        ['example.com', '22', 'alice', ''],
      );
      expect(tester.takeException(), isNull);
    },
  );
}
