import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../src/rust/api/client.dart' as native;
import 'command_history.dart';
import 'errors.dart';

/// Owns the terminal model, SSH output and session lifetime independently of
/// any widget. Views can attach, move and detach without reconnecting.
class TerminalSession extends ChangeNotifier {
  final String connectionId, host, username, hostId;
  final Terminal terminal = Terminal(maxLines: 5000);
  final VoidCallback onEnded;
  final void Function(String command)? onCommand;
  final VoidCallback? onActivity;
  final void Function(ZModemOffer offer)? onZmodemOffer;
  final Future<Iterable<ZModemOffer>> Function()? onZmodemRequest;
  final CommandLineTracker _commandTracker = CommandLineTracker();
  final StreamController<Uint8List> _wire = StreamController<Uint8List>(
    sync: true,
  );
  final StreamController<List<int>> _zmodemInput = StreamController<List<int>>(
    sync: true,
  );
  ZModemMux? _zmodem;
  StreamSubscription<Uint8List>? _output;
  Future<void> _writes = Future.value();
  Timer? _resizeTimer;
  bool _ended = false, _closed = false;
  final bool _offline;
  String? _error;
  int? _lastColumns, _lastRows;
  String? currentDirectory;
  static int _offlineSequence = 0;

  TerminalSession({
    required this.connectionId,
    required this.host,
    required this.username,
    required this.onEnded,
    this.onCommand,
    this.onActivity,
    this.onZmodemOffer,
    this.onZmodemRequest,
    this.hostId = '',
  }) : _offline = false {
    final mux = ZModemMux(stdout: _wire.stream, stdin: _zmodemInput.sink)
      ..onTerminalInput = terminal.write
      ..onFileOffer = (offer) {
        final handler = onZmodemOffer;
        if (handler == null) {
          offer.skip();
        } else {
          handler(offer);
        }
      }
      ..onFileRequest = onZmodemRequest;
    _zmodem = mux;
    _zmodemInput.stream.listen(
      (bytes) => unawaited(
        native
            .writeTerminal(connectionId: connectionId, bytes: bytes)
            .catchError((Object error) {
              _finish(userFacingError(error));
            }),
      ),
      onError: (Object error) => _finish(userFacingError(error)),
    );
    terminal.onOutput = send;
    terminal.onResize = _resize;
    terminal.onPrivateOSC = (code, args) {
      if (code != '7' || args.isEmpty) return;
      final uri = Uri.tryParse(args.first);
      final value = uri?.path;
      if (value == null || value.isEmpty) return;
      currentDirectory = Uri.decodeComponent(value);
      notifyListeners();
    };
    _output = native
        .terminalOutput(connectionId: connectionId)
        .listen(
          (data) {
            if (_closed) return;
            onActivity?.call();
            _wire.add(data);
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

  /// A restorable placeholder for a disconnected pane. It never owns a native
  /// connection; the pane's reconnect action replaces it with a live session.
  TerminalSession.offline({
    required this.host,
    required this.username,
    required this.onEnded,
    this.onCommand,
    this.onActivity,
    this.onZmodemOffer,
    this.onZmodemRequest,
    this.hostId = '',
  }) : connectionId =
           'offline-${DateTime.now().microsecondsSinceEpoch}-${_offlineSequence++}',
       _offline = true {
    _ended = true;
    terminal.onOutput = send;
    terminal.write('\r\n\x1b[90m上次会话已断开，使用“重新连接”恢复。\x1b[0m\r\n');
  }

  bool get ended => _ended;
  String? get error => _error;
  String get title => username.isEmpty ? host : '$username@$host';

  void send(String text, {bool record = true}) {
    if (_ended || _closed) return;
    if (record) {
      for (final command in _commandTracker.feed(text)) {
        onCommand?.call(command);
      }
    }
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
    terminal.onPrivateOSC = null;
    final output = _output;
    _output = null;
    await output?.cancel();
    if (!_offline) {
      _zmodem
        ?..onFileOffer = null
        ..onFileRequest = null;
      _zmodem = null;
      await _zmodemInput.close();
      await _wire.close();
      await native
          .disconnect(connectionId: connectionId)
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
