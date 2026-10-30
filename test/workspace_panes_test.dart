import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/workspace_layout.dart';

void main() {
  test('collects sessions and first pane in order', () {
    final tree = SplitPane(
      Axis.horizontal,
      const SessionPane('a'),
      SplitPane(Axis.vertical, const SessionPane('b'), const SessionPane('c')),
    );
    expect(sessionIds(tree), {'a', 'b', 'c'});
    expect(firstSession(tree), 'a');
    expect(containsSession(tree, 'c'), isTrue);
    expect(containsSession(tree, 'missing'), isFalse);
  });

  test('splits a target pane at each edge with the incoming subtree', () {
    final root = SplitPane(
      Axis.horizontal,
      const SessionPane('a'),
      const SessionPane('b'),
    );
    final left =
        splitAt(root, 'b', SplitEdge.left, const SessionPane('x')) as SplitPane;
    expect((left.first as SessionPane).sessionId, 'a');
    final leftTarget = left.second as SplitPane;
    expect(leftTarget.axis, Axis.horizontal);
    expect((leftTarget.first as SessionPane).sessionId, 'x');
    expect((leftTarget.second as SessionPane).sessionId, 'b');
    final top =
        splitAt(root, 'b', SplitEdge.top, const SessionPane('y')) as SplitPane;
    final topTarget = top.second as SplitPane;
    expect(topTarget.axis, Axis.vertical);
    expect((topTarget.first as SessionPane).sessionId, 'y');
    final bottom = splitAt(
      root,
      'a',
      SplitEdge.bottom,
      const SessionPane('z'),
    ) as SplitPane;
    final bottomTarget = bottom.first as SplitPane;
    expect(bottomTarget.axis, Axis.vertical);
    expect((bottomTarget.first as SessionPane).sessionId, 'a');
    expect((bottomTarget.second as SessionPane).sessionId, 'z');
    final nested = splitAt(
      root,
      'a',
      SplitEdge.right,
      SplitPane(Axis.vertical, const SessionPane('m'), const SessionPane('n')),
    ) as SplitPane;
    final nestedTarget = nested.first as SplitPane;
    expect(nestedTarget.axis, Axis.horizontal);
    expect((nestedTarget.second as SplitPane).axis, Axis.vertical);
    expect(sessionIds(nested), {'a', 'm', 'n', 'b'});
    expect(
      identical(
        splitAt(root, 'missing', SplitEdge.left, const SessionPane('q')),
        root,
      ),
      isTrue,
    );
  });

  test('removing panes folds empty splits', () {
    final root = SplitPane(
      Axis.horizontal,
      const SessionPane('a'),
      SplitPane(Axis.vertical, const SessionPane('b'), const SessionPane('c')),
    );
    final withoutA = removeSession(root, 'a')!;
    final vertical = withoutA as SplitPane;
    expect(vertical.axis, Axis.vertical);
    expect(sessionIds(vertical), {'b', 'c'});
    final withoutB = removeSession(vertical, 'b')!;
    expect((withoutB as SessionPane).sessionId, 'c');
    expect(removeSession(withoutB, 'c'), isNull);
    expect(removeSession(root, 'missing'), isNotNull);
  });

  test('tab edge helper matches split direction', () {
    expect(edgeForAxis(Axis.horizontal), SplitEdge.right);
    expect(edgeForAxis(Axis.vertical), SplitEdge.bottom);
  });

  test('ordered pane ids and four-pane preset follow layout order', () {
    final tree = SplitPane(
      Axis.horizontal,
      SplitPane(Axis.vertical, const SessionPane('a'), const SessionPane('b')),
      const SessionPane('c'),
    );
    expect(sessionIdsOrdered(tree), ['a', 'b', 'c']);
    final grid = fourPane(['a', 'b', 'c', 'd']);
    expect(sessionIdsOrdered(grid), ['a', 'b', 'c', 'd']);
    final root = grid as SplitPane;
    expect(root.axis, Axis.horizontal);
    expect((root.first as SplitPane).axis, Axis.vertical);
    expect((root.second as SplitPane).axis, Axis.vertical);
    expect(sessionIds(root), {'a', 'b', 'c', 'd'});
  });

  test('nearest edge accepts drops anywhere in a pane', () {
    const size = Size(1000, 600);
    expect(nearestSplitEdge(const Offset(20, 300), size), SplitEdge.left);
    expect(nearestSplitEdge(const Offset(980, 300), size), SplitEdge.right);
    expect(nearestSplitEdge(const Offset(500, 20), size), SplitEdge.top);
    expect(nearestSplitEdge(const Offset(500, 580), size), SplitEdge.bottom);
    expect(nearestSplitEdge(const Offset(500, 300), size), SplitEdge.top);
    expect(nearestSplitEdge(Offset.zero, Size.zero), SplitEdge.right);
  });

  test(
    'broadcast targets exclude source, disconnected and out-of-scope panes',
    () {
      List<String> targets(BroadcastScope scope, Set<String> connected) =>
          broadcastTargetIds(
            sourceId: 'a',
            scope: scope,
            tabSessionIds: const ['a', 'b'],
            allSessionIds: const ['a', 'b', 'c'],
            connectedSessionIds: connected,
          );
      expect(targets(BroadcastScope.off, {'a', 'b', 'c'}), isEmpty);
      expect(targets(BroadcastScope.tab, {'a', 'b', 'c'}), ['b']);
      expect(targets(BroadcastScope.all, {'a', 'b', 'c'}), ['b', 'c']);
      expect(targets(BroadcastScope.all, {'a', 'c'}), ['c']);
    },
  );

  test('replacing a pane keeps the split tree and proportions', () {
    final tree = SplitPane(
      Axis.horizontal,
      const SessionPane('a'),
      SplitPane(
        Axis.vertical,
        const SessionPane('b'),
        const SessionPane('c'),
        fraction: .3,
      ),
      fraction: .4,
    );
    final replaced = replaceSession(tree, 'b', 'reconnected') as SplitPane;
    expect(replaced.fraction, .4);
    expect(sessionIdsOrdered(replaced), ['a', 'reconnected', 'c']);
    final nested = replaced.second as SplitPane;
    expect(nested.axis, Axis.vertical);
    expect(nested.fraction, .3);
    expect(sessionIdsOrdered(replaceSession(tree, 'missing', 'x')), [
      'a',
      'b',
      'c',
    ]);
  });
}
