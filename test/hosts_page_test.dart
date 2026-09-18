import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_store.dart';
import 'package:wterm/features/hosts_page.dart';
import 'package:wterm/features/connect_dialog.dart';

class MemoryHosts implements HostStore {
  List<HostProfile> hosts = [];
  bool failWrite = false, failRead = false;
  @override
  Future<List<HostProfile>> read() async {
    if (failRead) throw const FormatException('corrupt');
    return [...hosts];
  }

  @override
  Future<void> write(List<HostProfile> next) async {
    if (failWrite) throw StateError('locked');
    hosts = [...next];
  }
}

void main() {
  testWidgets(
    'phone adds, searches, favorites, edits and deletes a persisted host',
    (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryHosts();
      await tester.pumpWidget(MaterialApp(home: HostsPage(store: store)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加主机'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      for (final entry in {
        0: 'Production',
        1: 'example.com',
        2: '2222',
        3: 'alice',
        4: 'Work',
        5: 'api， api, linux',
      }.entries) {
        await tester.enterText(fields.at(entry.key), entry.value);
      }
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.hosts.single.tags, ['api', 'linux']);
      await tester.tap(find.byTooltip('主机操作：Production'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏主机'));
      await tester.pumpAndSettle();
      expect(store.hosts.single.favorite, isTrue);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的主机'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'API');
      await tester.pumpAndSettle();
      expect(find.text('Production'), findsOneWidget);
      await tester.tap(find.byTooltip('主机操作：Production'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      final oldId = store.hosts.single.id;
      await tester.enterText(find.byType(TextFormField).first, 'Renamed');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.hosts.single.id, oldId);
      expect(store.hosts.single.favorite, isTrue);
      await tester.tap(find.byTooltip('主机操作：Renamed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(store.hosts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed mutation retains visible data; failed read disables writes',
    (tester) async {
      final store = MemoryHosts()
        ..hosts = [
          HostProfile(id: 'a', name: 'A', host: 'host', username: 'user'),
        ]
        ..failWrite = true;
      await tester.pumpWidget(MaterialApp(home: HostsPage(store: store)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('主机操作：A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏主机'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('主机操作：A'), findsOneWidget);
      expect(store.hosts.single.favorite, isFalse);
      expect(find.textContaining('保存失败'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      store.failRead = true;
      await tester.pumpWidget(MaterialApp(home: HostsPage(store: store)));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '添加主机',
              ),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('saved profile prefills endpoint while credentials stay empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectDialog(
            profile: HostProfile(
              id: 'a',
              name: 'A',
              host: 'example.com',
              port: 2222,
              username: 'alice',
            ),
          ),
        ),
      ),
    );
    final values = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .map((f) => f.controller!.text)
        .toList();
    expect(values, ['example.com', '2222', 'alice', '']);
  });
}
