import '../src/rust/api/forward.dart' as native;

/// Saved forwarding rules are device-local vault metadata.
abstract interface class ForwardRuleStore {
  Future<List<native.ForwardRule>> forwardRules(String hostId);
  Future<native.ForwardRule> saveForwardRule(native.ForwardRule rule);
  Future<void> deleteForwardRule(String id);
}

abstract interface class ForwardingStore {
  Future<List<native.ForwardInfo>> listForwards();
  Future<native.ForwardInfo> startForward({
    required String kind,
    required String listenHost,
    required int listenPort,
    String targetHost = '',
    int targetPort = 0,
  });
  Future<void> stopForward(String id);
  Future<List<native.ForwardRule>> forwardRules();
  Future<native.ForwardRule> saveForwardRule(native.ForwardRule rule);
  Future<void> deleteForwardRule(String id);
}

class SessionForwardingStore implements ForwardingStore {
  final String connectionId;
  final String hostId;
  final ForwardRuleStore? rules;
  SessionForwardingStore({
    required this.connectionId,
    required this.hostId,
    this.rules,
  });

  @override
  Future<List<native.ForwardInfo>> listForwards() =>
      native.listForwards(connectionId: connectionId);

  @override
  Future<native.ForwardInfo> startForward({
    required String kind,
    required String listenHost,
    required int listenPort,
    String targetHost = '',
    int targetPort = 0,
  }) => native.startForward(
    connectionId: connectionId,
    kind: kind,
    listenHost: listenHost,
    listenPort: listenPort,
    targetHost: targetHost,
    targetPort: targetPort,
  );

  @override
  Future<void> stopForward(String id) =>
      native.stopForward(connectionId: connectionId, forwardId: id);

  @override
  Future<List<native.ForwardRule>> forwardRules() async {
    if (hostId.isEmpty || rules == null) return [];
    return rules!.forwardRules(hostId);
  }

  @override
  Future<native.ForwardRule> saveForwardRule(native.ForwardRule rule) {
    if (hostId.isEmpty || rules == null) {
      throw StateError('临时连接不能保存转发规则');
    }
    return rules!.saveForwardRule(rule);
  }

  @override
  Future<void> deleteForwardRule(String id) {
    if (rules == null) throw StateError('当前存储不支持转发规则');
    return rules!.deleteForwardRule(id);
  }
}
