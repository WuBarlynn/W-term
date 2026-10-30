import 'host_store.dart';
import 'trust_store.dart';

const maxRouteJumps = 4;

class RouteException implements Exception {
  final String message;
  const RouteException(this.message);
  @override
  String toString() => message;
}

class RouteHop {
  final HostProfile host;

  /// Trust is scoped to the path, so the same internal address reached through
  /// another route (or directly) is verified separately.
  final String trustKey;
  final List<String> via;

  const RouteHop({
    required this.host,
    required this.trustKey,
    required this.via,
  });

  bool get isJump => via.isNotEmpty;
  String get label => via.isEmpty
      ? '${host.name} (${host.host}:${host.port})'
      : '${host.name} (${host.host}:${host.port})，经 ${via.join(' → ')}';
}

/// Expands saved jump references into an ordered hop list ending at [target].
/// Missing or cyclic references fail before any network connection starts.
List<RouteHop> buildRoute(
  HostProfile target,
  Map<String, HostProfile> saved, {
  int maxJumps = maxRouteJumps,
}) {
  final hops = <HostProfile>[];
  final visiting = <String>{};
  final visited = <String>{};
  void visit(HostProfile host, int depth) {
    if (visiting.contains(host.id)) {
      throw const RouteException('跳板路线存在循环引用');
    }
    if (visited.contains(host.id)) {
      throw RouteException('跳板路线重复经过「${host.name}」');
    }
    if (depth > maxJumps) {
      throw RouteException('跳板路线最多 $maxJumps 台跳板主机');
    }
    visiting.add(host.id);
    for (final id in host.jumpHostIds) {
      final jump = saved[id];
      if (jump == null) {
        throw RouteException('跳板主机「${host.name}」引用的主机不存在，请重新编辑路线');
      }
      visit(jump, depth + 1);
    }
    visiting.remove(host.id);
    visited.add(host.id);
    hops.add(host);
  }

  visit(target, 0);
  if (hops.length - 1 > maxJumps) {
    throw RouteException('跳板路线最多 $maxJumps 台跳板主机');
  }
  final route = <RouteHop>[];
  final via = <String>[];
  for (final host in hops) {
    final endpoint = endpointKey(host.host, host.port);
    route.add(
      RouteHop(
        host: host,
        trustKey: [...via, endpoint].join(' > '),
        via: List.unmodifiable(via),
      ),
    );
    via.add(endpoint);
  }
  return route;
}

/// Route metadata stored in each host is shallow; nested routes are expanded
/// only when connecting, so a jump host can be edited independently.
bool hostUsesAsJump(List<HostProfile> hosts, String hostId) =>
    hosts.any((h) => h.jumpHostIds.contains(hostId));
