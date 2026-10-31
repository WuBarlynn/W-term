import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../src/rust/api/client.dart' as native;
import 'command_history.dart';
import 'errors.dart';

/// Marks user-originated terminal input so broadcast never forwards protocol
/// replies (device attributes, cursor reports, mouse reports) to other hosts.
class _WTermTerminal extends Terminal {
  _WTermTerminal({super.maxLines});
  bool userInput = false;

  T _mark<T>(T Function() action) {
    userInput = true;
    try {
      return action();
    } finally {
      userInput = false;
    }
  }

  @override
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) => _mark(() => super.keyInput(key, shift: shift, alt: alt, ctrl: ctrl));

  @override
  bool charInput(int charCode, {bool alt = false, bool ctrl = false}) =>
      _mark(() => super.charInput(charCode, alt: alt, ctrl: ctrl));

  @override
  void textInput(String text) => _mark(() => super.textInput(text));

  @override
  void paste(String text) => _mark(() => super.paste(text));
}

/// Owns the terminal model, SSH output and session lifetime independently of
/// any widget. Views can attach, move and detach without reconnecting.
class TerminalSession extends ChangeNotifier {
  final String connectionId, host, username, hostId;
  final Terminal terminal = _WTermTerminal(maxLines: 5000);
  final VoidCallback onEnded;
  final void Function(String command)? onCommand;
  void Function(int? exitCode)? onCommandFinished;
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
  bool _ended = false, _closed = false, _handedOff = false, _handingOff = false;
  bool _local = false;
  Pty? _pty;
  StreamSubscription<String>? _localOutput;
  final bool _offline;
  final List<void Function(String text)> _inputListeners = [];

  /// Resolves the broadcast targets at input time so pane moves, tab changes
  /// and disconnects are always reflected without rebinding the terminal.
  List<TerminalSession> Function()? broadcastTargets;
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
    this.onCommandFinished,
    this.onActivity,
    this.onZmodemOffer,
    this.onZmodemRequest,
    this.hostId = '',
  }) : _offline = false {
    _startLive();
  }

  /// Reattaches to a connection whose output receiver was handed off by
  /// another engine. The snapshot restores scrollback for the new view.
  TerminalSession.attach({
    required this.connectionId,
    required this.host,
    required this.username,
    required String snapshot,
    required this.onEnded,
    this.onCommand,
    this.onCommandFinished,
    this.onActivity,
    this.onZmodemOffer,
    this.onZmodemRequest,
    this.hostId = '',
  }) : _offline = false {
    if (snapshot.isNotEmpty) terminal.write(snapshot);
    _startLive();
  }

  /// A desktop local shell backed by a real PTY; it never touches Rust/SSH.
  TerminalSession.local({
    required this.host,
    required this.username,
    required this.onEnded,
    this.onCommand,
    this.onCommandFinished,
    this.onActivity,
    this.onZmodemOffer,
    this.onZmodemRequest,
    this.hostId = '',
  }) : connectionId =
           'local-${DateTime.now().microsecondsSinceEpoch}-${_offlineSequence++}',
       _offline = false {
    _local = true;
    terminal.onOutput = _handleTerminalInput;
    terminal.onResize = _resize;
    terminal.onPrivateOSC = _handlePrivateOsc;
    unawaited(_startLocalPty());
  }

  Future<void> _startLocalPty() async {
    if (_closed) return;
    final executable = Platform.isWindows
        ? (Platform.environment['COMSPEC'] ?? 'cmd.exe')
        : (Platform.environment['SHELL'] ?? '/bin/zsh');
    try {
      final pty = Pty.start(
        executable,
        arguments: Platform.isWindows ? const [] : const ['-l'],
        rows: 24,
        columns: 80,
        environment: const {'TERM': 'xterm-256color'},
      );
      if (_closed) {
        pty.kill();
        return;
      }
      _pty = pty;
      _localOutput = utf8.decoder
          .bind(pty.output)
          .listen(
            (text) {
              onActivity?.call();
              terminal.write(text);
            },
            onError: (Object error) => _finish(userFacingError(error)),
            onDone: () => _finish(null),
          );
      unawaited(pty.exitCode.then((_) => _finish(null)));
    } catch (e) {
      _finish(userFacingError(e));
    }
  }

  bool get isLocal => _local;

  void _handlePrivateOsc(String code, List<String> args) {
    if (code == '133') {
      if (args.isNotEmpty && args.first == 'D') {
        final exitCode = args.length > 1 ? int.tryParse(args[1]) : null;
        onCommandFinished?.call(exitCode);
      }
      return;
    }
    if (code != '7' || args.isEmpty) return;
    final uri = Uri.tryParse(args.first);
    final value = uri?.path;
    if (value == null || value.isEmpty) return;
    currentDirectory = Uri.decodeComponent(value);
    notifyListeners();
  }

  void _startLive() {
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
    terminal.onOutput = _handleTerminalInput;
    terminal.onResize = _resize;
    terminal.onPrivateOSC = _handlePrivateOsc;
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
          onError: (Object error) {
            if (!_handingOff) _finish(userFacingError(error));
          },
          onDone: () {
            if (!_handingOff) _finish(null);
          },
        );
  }

  /// A restorable placeholder for a disconnected pane. It never owns a native
  /// connection; the pane's reconnect action replaces it with a live session.
  TerminalSession.offline({
    required this.host,
    required this.username,
    required this.onEnded,
    this.onCommand,
    this.onCommandFinished,
    this.onActivity,
    this.onZmodemOffer,
    this.onZmodemRequest,
    this.hostId = '',
  }) : connectionId =
           'offline-${DateTime.now().microsecondsSinceEpoch}-${_offlineSequence++}',
       _offline = true {
    _ended = true;
    terminal.onOutput = _handleTerminalInput;
    terminal.onPrivateOSC = _handlePrivateOsc;
    terminal.write('\r\n\x1b[90m上次会话已断开，使用“重新连接”恢复。\x1b[0m\r\n');
  }

  bool get ended => _ended;
  String? get error => _error;
  String get title => username.isEmpty ? host : '$username@$host';

  String _bufferText() {
    final lines = <String>[];
    for (var i = 0; i < terminal.buffer.lines.length; i++) {
      final line = terminal.buffer.lines[i];
      if (line.isWrapped && lines.isNotEmpty) {
        lines[lines.length - 1] += line.getText();
      } else {
        lines.add(line.getText());
      }
    }
    return lines.join('\n');
  }

  /// Hands the Rust output receiver to another engine without disconnecting.
  /// Returns the scrollback snapshot for the new view.
  Future<String> detachForHandoff() async {
    if (_handedOff || _closed || _offline || _local) {
      throw StateError('该会话不能转移到新窗口');
    }
    final snapshot = _bufferText();
    _handingOff = true;
    try {
      await native.handoffTerminalOutput(connectionId: connectionId);
    } catch (_) {
      _handingOff = false;
      rethrow;
    }
    _handedOff = true;
    _closed = true;
    await _stopLocalOutput();
    return snapshot;
  }

  Future<void> _stopLocalOutput() async {
    _resizeTimer?.cancel();
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.onPrivateOSC = null;
    final output = _output;
    _output = null;
    await output?.cancel();
    _zmodem
      ?..onFileOffer = null
      ..onFileRequest = null;
    _zmodem = null;
    await _zmodemInput.close();
    await _wire.close();
  }

  /// Terminal-originated input (typing, paste, completion) is routed through
  /// the session so broadcast targets receive the same bytes. The routing is
  /// independent of panes, which means splitting, moving or closing a pane can
  /// never disable broadcast.
  void _handleTerminalInput(String text) {
    if ((terminal as _WTermTerminal).userInput) {
      sendInput(text);
    } else {
      send(text, record: false);
    }
  }

  void sendInput(String text, {bool record = true}) {
    if (_ended || _closed || text.isEmpty) return;
    send(text, record: record);
    for (final target
        in broadcastTargets?.call() ?? const <TerminalSession>[]) {
      if (identical(target, this)) continue;
      target.send(text, record: false);
    }
    for (final listener in List.of(_inputListeners)) {
      listener(text);
    }
  }

  void addInputListener(void Function(String text) listener) {
    if (!_inputListeners.contains(listener)) _inputListeners.add(listener);
  }

  void removeInputListener(void Function(String text) listener) {
    _inputListeners.remove(listener);
  }

  void send(String text, {bool record = true}) {
    if (_ended || _closed) return;
    if (record) {
      for (final command in _commandTracker.feed(text)) {
        onCommand?.call(command);
      }
    }
    if (_local) {
      _pty?.write(Uint8List.fromList(utf8.encode(text)));
      return;
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
      if (_local) {
        _pty?.resize(r, c);
        return;
      }
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
    if (_local) {
      _resizeTimer?.cancel();
      terminal.onOutput = null;
      terminal.onResize = null;
      terminal.onPrivateOSC = null;
      _pty?.kill();
      _pty = null;
      await _localOutput?.cancel();
      _localOutput = null;
    } else if (!_offline) {
      // Disconnect first: it closes the Rust output/ack channels, which lets a
      // pending terminalOutput stream subscription cancel instead of waiting
      // for its 60-second acknowledgement timeout.
      await native
          .disconnect(connectionId: connectionId)
          .catchError((Object _) {});
      await _stopLocalOutput();
    } else {
      _resizeTimer?.cancel();
      terminal.onOutput = null;
      terminal.onResize = null;
      terminal.onPrivateOSC = null;
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
