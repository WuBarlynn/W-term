import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/file_browser_filter.dart';
import 'package:wterm/src/rust/api/client.dart';

RemoteEntry entry(
  String name, {
  int size = 0,
  int? time,
  bool directory = false,
}) => RemoteEntry(
  name: name,
  path: '/$name',
  isDirectory: directory,
  isSymlink: false,
  size: size,
  modifiedAt: time,
);
void main() {
  final entries = [
    entry('zFolder', directory: true),
    entry('.env'),
    entry('中文.txt', time: 3),
    entry('Alpha', size: 40, time: 1),
    entry('beta', size: 10, time: 2),
  ];
  test('case-insensitive search and hidden filtering do not mutate original listing', () {
    final result = filterRemoteEntries(
      entries,
      query: ' ALP ',
      showHidden: false,
      sort: FileSort.name,
      descending: false,
    );
    expect(result.map((e) => e.name), ['Alpha']);
    expect(
      filterRemoteEntries(
        entries,
        query: '中文',
        showHidden: true,
        sort: FileSort.name,
        descending: false,
      ).single.name,
      '中文.txt',
    );
    expect(
      filterRemoteEntries(
        entries,
        query: '.env',
        showHidden: false,
        sort: FileSort.name,
        descending: false,
      ),
      isEmpty,
    );
    expect(entries.first.name, 'zFolder');
    expect(entries.length, 5);
  });
  test(
    'directories remain first and unknown dates last in both directions',
    () {
      for (final descending in [false, true]) {
        final result = filterRemoteEntries(
          entries,
          query: '',
          showHidden: true,
          sort: FileSort.modified,
          descending: descending,
        );
        expect(result.first.name, 'zFolder');
        expect(result.last.name, '.env');
        expect(result[1].name, descending ? '中文.txt' : 'Alpha');
      }
      final result = filterRemoteEntries(
        entries,
        query: '',
        showHidden: false,
        sort: FileSort.size,
        descending: true,
      );
      expect(result.map((e) => e.name), ['zFolder', 'Alpha', 'beta', '中文.txt']);
    },
  );
  test('missing date is not presented as Unix epoch', () {
    expect(remoteModifiedLabel(null), '修改时间未知');
    expect(
      remoteModifiedLabel(1700000000),
      matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
    );
  });
  testWidgets('narrow controls search clear toggle and sort', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final search = TextEditingController();
    addTearDown(search.dispose);
    var hidden = true, descending = false;
    var sort = FileSort.name;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => FileBrowserControls(
              search: search,
              showHidden: hidden,
              descending: descending,
              sort: sort,
              onFilterChanged: () => setState(() {}),
              onToggleHidden: () => setState(() => hidden = !hidden),
              onToggleDirection: () => setState(() => descending = !descending),
              onSort: (v) => setState(() => sort = v),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'test');
    await tester.pump();
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(search.text, isEmpty);
    await tester.tap(find.byTooltip('隐藏点文件'));
    await tester.pump();
    expect(hidden, false);
    await tester.tap(find.byTooltip('排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改时间'));
    await tester.pumpAndSettle();
    expect(sort, FileSort.modified);
    await tester.tap(find.byTooltip('升序，点击切换降序'));
    await tester.pump();
    expect(descending, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
