import 'dart:convert';

/// Payload passed between the main workspace and a detached terminal window.
/// Kept as a small typed object so both the macOS native bridge and the
/// Windows cross-window channel validate the same fields.
class SessionHandoffPayload {
  final String connectionId;
  final String host;
  final String username;
  final String hostId;
  final String snapshot;
  final String title;
  const SessionHandoffPayload({
    required this.connectionId,
    required this.host,
    this.username = '',
    this.hostId = '',
    this.snapshot = '',
    this.title = '',
  });

  Map<String, String> toMap() => {
    'connectionId': connectionId,
    'host': host,
    'username': username,
    'hostId': hostId,
    'snapshot': snapshot,
    'title': title,
  };

  String encode() => jsonEncode(toMap());

  static SessionHandoffPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final connectionId = '${value['connectionId'] ?? ''}';
      final host = '${value['host'] ?? ''}';
      if (connectionId.isEmpty || host.isEmpty) return null;
      return SessionHandoffPayload(
        connectionId: connectionId,
        host: host,
        username: '${value['username'] ?? ''}',
        hostId: '${value['hostId'] ?? ''}',
        snapshot: '${value['snapshot'] ?? ''}',
        title: '${value['title'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}
