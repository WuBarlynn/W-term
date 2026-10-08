import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/directory_history.dart';
import 'package:wterm/features/directory_history_bar.dart';

void main() {
  test(
    'refresh preserves forward history and new navigation creates a branch',
    () {
      final history = DirectoryHistory();
      for (final path in ['/a', '/b', '/c']) {
        history.commit(path);
      }
      history.commit('/b', historyIndex: history.backIndex);
      history.commit('/b');
      expect(history.paths, ['/a', '/b', '/c']);
      expect(history.forwardIndex, 2);
      history.commit('/d');
      expect(history.paths, ['/a', '/b', '/d']);
      expect(history.forwardIndex, isNull);
    },
  );
  test('failed navigation leaves history untouched until explicit commit', () {
    final history = DirectoryHistory()
      ..commit('/a')
      ..commit('/b');
    final target = history.paths[history.backIndex!];
    expect(target, '/a');
    expect(history.current, '/b');
    expect(history.index, 1);
    history.commit('/resolved-a', historyIndex: 0);
    expect(history.current, '/resolved-a');
    expect(history.paths, ['/resolved-a', '/b']);
  });
  test('history is bounded and duplicate canonical paths do not grow it', () {
    final history = DirectoryHistory(limit: 3);
    for (final path in ['/a', '/b', '/c', '/d', '/d']) {
      history.commit(path);
    }
    expect(history.paths, ['/b', '/c', '/d']);
    expect(history.index, 2);
    expect(() => history.paths.add('/e'), throwsUnsupportedError);
  });
  testWidgets(
    'phone navigation requests correct index and disables while loading',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = DirectoryHistory()
        ..commit('/a')
        ..commit('/b');
      int? requested;
      Future<void> render(bool busy) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryHistoryBar(
              history: history,
              busy: busy,
              onNavigate: (index) => requested = index,
            ),
          ),
        ),
      );
      await render(false);
      await tester.tap(find.byTooltip('后退目录'));
      expect(requested, 0);
      expect(history.current, '/b');
      requested = null;
      await render(true);
      await tester.tap(find.byTooltip('后退目录'));
      expect(requested, isNull);
      await render(false);
      await tester.tap(find.byTooltip('目录历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/a'));
      await tester.pumpAndSettle();
      expect(requested, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
