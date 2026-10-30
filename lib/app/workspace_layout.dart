import 'package:flutter/widgets.dart';

enum SplitEdge { left, right, top, bottom }

enum BroadcastScope { off, tab, all }

/// Sessions that receive a pane's keystrokes. The source pane is excluded and
/// only currently connected sessions are eligible.
List<String> broadcastTargetIds({
  required String sourceId,
  required BroadcastScope scope,
  required Iterable<String> tabSessionIds,
  required Iterable<String> allSessionIds,
  required Set<String> connectedSessionIds,
}) {
  if (scope == BroadcastScope.off) return const [];
  final candidates = scope == BroadcastScope.tab
      ? tabSessionIds
      : allSessionIds;
  return [
    for (final id in candidates)
      if (id != sourceId && connectedSessionIds.contains(id)) id,
  ];
}

sealed class PaneNode {
  const PaneNode();
}

final class SessionPane extends PaneNode {
  final String sessionId;
  const SessionPane(this.sessionId);
}

final class SplitPane extends PaneNode {
  final Axis axis;
  PaneNode first, second;
  double fraction;
  SplitPane(this.axis, this.first, this.second, {this.fraction = 0.5});
}

class WorkspaceTab {
  final String id;
  PaneNode root;
  String activeSessionId;
  String? customName;
  WorkspaceTab({
    required this.id,
    required this.root,
    required this.activeSessionId,
    this.customName,
  });
}

Set<String> sessionIds(PaneNode node) => sessionIdsOrdered(node).toSet();

/// Pane order as shown left-to-right/top-to-bottom, used for layout presets.
List<String> sessionIdsOrdered(PaneNode node) => switch (node) {
  SessionPane(:final sessionId) => [sessionId],
  SplitPane(:final first, :final second) => [
    ...sessionIdsOrdered(first),
    ...sessionIdsOrdered(second),
  ],
};

/// Arranges exactly four sessions in a 2×2 grid.
PaneNode fourPane(List<String> ids) {
  assert(ids.length == 4, 'fourPane requires four session ids');
  return SplitPane(
    Axis.horizontal,
    SplitPane(Axis.vertical, SessionPane(ids[0]), SessionPane(ids[1])),
    SplitPane(Axis.vertical, SessionPane(ids[2]), SessionPane(ids[3])),
  );
}

bool containsSession(PaneNode node, String sessionId) =>
    sessionIds(node).contains(sessionId);

String? firstSession(PaneNode node) => switch (node) {
  SessionPane(:final sessionId) => sessionId,
  SplitPane(:final first) => firstSession(first),
};

/// Removes one pane and folds empty splits. Returns null when the tree is empty.
PaneNode? removeSession(PaneNode node, String sessionId) {
  if (node is SessionPane) {
    return node.sessionId == sessionId ? null : node;
  }
  final split = node as SplitPane;
  final first = removeSession(split.first, sessionId);
  final second = removeSession(split.second, sessionId);
  if (first == null) return second;
  if (second == null) return first;
  return SplitPane(split.axis, first, second, fraction: split.fraction);
}

/// Swaps a pane's session id without changing the split tree or proportions.
PaneNode replaceSession(
  PaneNode node,
  String oldSessionId,
  String newSessionId,
) {
  if (node is SessionPane) {
    return node.sessionId == oldSessionId ? SessionPane(newSessionId) : node;
  }
  final split = node as SplitPane;
  return SplitPane(
    split.axis,
    replaceSession(split.first, oldSessionId, newSessionId),
    replaceSession(split.second, oldSessionId, newSessionId),
    fraction: split.fraction,
  );
}

/// Splits the pane showing [targetSessionId] at [edge] and inserts [incoming].
/// The tree is returned unchanged when the target is not present.
PaneNode splitAt(
  PaneNode node,
  String targetSessionId,
  SplitEdge edge,
  PaneNode incoming,
) {
  if (node is SessionPane) {
    if (node.sessionId != targetSessionId) return node;
    final horizontal = edge == SplitEdge.left || edge == SplitEdge.right;
    final incomingFirst = edge == SplitEdge.left || edge == SplitEdge.top;
    return SplitPane(
      horizontal ? Axis.horizontal : Axis.vertical,
      incomingFirst ? incoming : node,
      incomingFirst ? node : incoming,
    );
  }
  final split = node as SplitPane;
  if (containsSession(split.first, targetSessionId)) {
    return SplitPane(
      split.axis,
      splitAt(split.first, targetSessionId, edge, incoming),
      split.second,
      fraction: split.fraction,
    );
  }
  if (containsSession(split.second, targetSessionId)) {
    return SplitPane(
      split.axis,
      split.first,
      splitAt(split.second, targetSessionId, edge, incoming),
      fraction: split.fraction,
    );
  }
  return node;
}

SplitEdge edgeForAxis(Axis axis) =>
    axis == Axis.horizontal ? SplitEdge.right : SplitEdge.bottom;

/// Picks the pane edge nearest to a drop position so a tab can be dropped
/// anywhere in the pane instead of only on a narrow edge strip.
SplitEdge nearestSplitEdge(Offset position, Size size) {
  if (size.isEmpty) return SplitEdge.right;
  final distances = {
    SplitEdge.left: position.dx,
    SplitEdge.right: size.width - position.dx,
    SplitEdge.top: position.dy,
    SplitEdge.bottom: size.height - position.dy,
  };
  return distances.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
}
