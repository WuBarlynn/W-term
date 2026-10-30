import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../src/rust/api/client.dart' as native;
import 'errors.dart';

/// Owns the terminal model, SSH output and session lifetime independently of
/// any widget. Views can attach, move and detach without reconnecting.
class TerminalSession extends ChangeNotifier {
  final String connectionId, host, username;
  final Terminal terminal = Terminal(maxLines: 5000);
  final VoidCallback onEnded;
  final StreamController<List<int>> _bytes = StreamController<List<int>>(
    sync: true,
  );
  late final StreamSubscription<String> _decoded;
  StreamSubscription<Uint8List>? _output;
  Future<void> _writes = Future.value();
  Timer? _resizeTimer;
  bool _ended = false, _closed = false;
  String? _error;
  int? _lastColumns, _lastRows;

  TerminalSession({
    required this.connectionId,
    required this.host,
    required this.username,
    required this.onEnded,
  }) {
    _decoded = utf8.decoder
        .bind(_bytes.stream)
        .listen(terminal.write, onError: (_) {});
    terminal.onOutput = send;
    terminal.onResize = _resize;
    _output = native
        .terminalOutput(connectionId: connectionId)
        .listen(
          (data) {
            if (_closed) return;
            _bytes.add(data);
            unawaited(
              native
                  .acknowledgeOutput(connectionId: connectionId)
                  .catchError((Object _) {}),
            );
          },
          onError: (Object error) => _finish(userFacingError(error)),
          onDone: () => _finish(null),
        );
  }

  bool get ended => _ended;
  String? get error => _error;
  String get title => username.isEmpty ? host : '$username@$host';

  void send(String text) {
    if (_ended || _closed) return;
    _writes = _writes
        .then(
          (_) => native.writeTerminal(
            connectionId: connectionId,
            bytes: utf8.encode(text),
          ),
        )
        .catchError((Object error) {
          _finish(userFacingError(error));
        });
  }

  void _resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (_ended || _closed) return;
    _lastColumns = columns;
    _lastRows = rows;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 80), () {
      if (_ended || _closed) return;
      final c = _lastColumns, r = _lastRows;
      if (c == null || r == null) return;
      unawaited(
        native
            .resizeTerminal(connectionId: connectionId, columns: c, rows: r)
            .catchError((Object _) {}),
      );
    });
  }

  void _finish(String? error) {
    if (_ended || _closed) return;
    _ended = true;
    _error = error;
    terminal.write(
      '\r\n\x1b[90m${error == null ? '连接已结束' : '连接中断：$error'}\x1b[0m\r\n',
    );
    notifyListeners();
    onEnded();
  }

  /// Cancels output handling and disconnects the SSH session. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_ended) {
      _ended = true;
      terminal.write('\r\n\x1b[90m连接已结束\x1b[0m\r\n');
    }
    _resizeTimer?.cancel();
    terminal.onOutput = null;
    terminal.onResize = null;
    final output = _output;
    _output = null;
    await output?.cancel();
    await _decoded.cancel();
    await _bytes.close();
    await native
        .disconnect(connectionId: connectionId)
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
