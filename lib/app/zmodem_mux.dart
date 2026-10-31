import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/zmodem.dart' as xterm;
import 'package:zmodem/zmodem.dart' as zm;

/// Serialized ZMODEM bridge. The upstream xterm mux buffers an entire outgoing
/// file before flushing, which stalls lrzsz over a real terminal; this bridge
/// flushes every data subpacket and processes incoming chunks in order.
class WTermZModemMux {
  final Stream<Uint8List> stdout;
  final StreamSink<List<int>> stdin;

  void Function(String output)? onTerminalInput;
  void Function(xterm.ZModemOffer offer)? onFileOffer;
  Future<Iterable<xterm.ZModemOffer>> Function()? onFileRequest;

  static const _senderInit = [0x2a, 0x2a, 0x18, 0x42, 0x30, 0x30];
  static const _receiverInit = [0x2a, 0x2a, 0x18, 0x42, 0x30, 0x31];

  late final StreamSubscription<Uint8List> _subscription;
  late final StreamController<List<int>> _terminalSink;
  zm.ZModemCore? _session;
  StreamController<Uint8List>? _receiveSink;
  Iterator<xterm.ZModemOffer>? _fileOffers;
  Future<void> _chain = Future.value();
  bool _closed = false;

  WTermZModemMux({required this.stdin, required this.stdout}) {
    _terminalSink = StreamController<List<int>>()
      ..stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) => onTerminalInput?.call(text));
    _subscription = stdout.listen(_handleStdout);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _session = null;
    unawaited(_closeReceiveSink());
    unawaited(_subscription.cancel().catchError((Object _) {}));
    unawaited(_terminalSink.close().catchError((Object _) {}));
  }

  void terminalWrite(String input) {
    if (_session == null && !_closed) stdin.add(utf8.encode(input));
  }

  void _handleStdout(Uint8List chunk) {
    if (_closed) return;
    if (_session != null) {
      _chain = _chain
          .then((_) => _processChunk(chunk))
          .catchError((Object error, StackTrace _) {
            _closeWithError(error);
          });
      return;
    }
    final index = _indexOf(chunk, _senderInit) ?? _indexOf(chunk, _receiverInit);
    if (index == null) {
      if (chunk.isNotEmpty) _terminalSink.add(chunk);
      return;
    }
    if (index > 0) _terminalSink.add(Uint8List.sublistView(chunk, 0, index));
    _session = zm.ZModemCore(
      onPlainText: (text) => _terminalSink.add([text]),
    );
    final rest = Uint8List.sublistView(chunk, index);
    _chain = _chain.then((_) => _processChunk(rest)).catchError((
      Object error,
      StackTrace _,
    ) {
      _closeWithError(error);
    });
  }

  int? _indexOf(Uint8List haystack, List<int> needle) {
    if (needle.length > haystack.length) return null;
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      var found = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return null;
  }

  Future<void> _processChunk(Uint8List chunk) async {
    final session = _session;
    if (session == null) return;
    try {
      for (final event in session.receive(chunk)) {
        if (event is zm.ZFileOfferedEvent) {
          _handleOffer(event);
        } else if (event is zm.ZFileDataEvent) {
          _receiveSink?.add(Uint8List.fromList(event.data));
        } else if (event is zm.ZFileEndEvent) {
          await _closeReceiveSink();
        } else if (event is zm.ZSessionFinishedEvent) {
          _flush();
          await _reset();
          return;
        } else if (event is zm.ZReadyToSendEvent) {
          _fileOffers ??= (await onFileRequest?.call())?.iterator;
          _moveToNextOffer();
        } else if (event is zm.ZFileAcceptedEvent) {
          await _sendAccepted(event);
        } else if (event is zm.ZFileSkippedEvent) {
          _fileOffers?.current.skip();
          _moveToNextOffer();
        }
        _flush();
      }
      _flush();
    } catch (error) {
      _closeWithError(error);
    }
  }

  void _handleOffer(zm.ZFileOfferedEvent event) {
    final handler = onFileOffer;
    if (handler == null) {
      _session!.skipFile();
      return;
    }
    handler(
      xterm.ZModemCallbackOffer(
        xterm.ZModemFileInfo(
          pathname: event.fileInfo.pathname,
          length: event.fileInfo.length,
          modificationTime: event.fileInfo.modificationTime,
          mode: event.fileInfo.mode,
          filesRemaining: event.fileInfo.filesRemaining,
          bytesRemaining: event.fileInfo.bytesRemaining,
        ),
        onAccept: (offset) {
          _session!.acceptFile(offset);
          _flush();
          _receiveSink = StreamController<Uint8List>();
          return _receiveSink!.stream;
        },
        onSkip: () {
          _session!.skipFile();
          _flush();
        },
      ),
    );
  }

  Future<void> _sendAccepted(zm.ZFileAcceptedEvent event) async {
    final session = _session!;
    final offer = _fileOffers?.current;
    if (offer == null) return;
    var sent = 0;
    await for (final chunk in offer.accept(event.offset)) {
      if (_closed) return;
      session.sendFileData(chunk);
      final data = session.dataToSend();
      if (data.isNotEmpty) stdin.add(data);
      sent += chunk.length;
    }
    session.finishSending(event.offset + sent);
    final data = session.dataToSend();
    if (data.isNotEmpty) stdin.add(data);
  }

  void _moveToNextOffer() {
    if (_fileOffers?.moveNext() != true) {
      _session?.finishSession();
      _flush();
      return;
    }
    _session!.offerFile(_fileOffers!.current.info);
  }

  Future<void> _closeReceiveSink() async {
    await _receiveSink?.close();
    _receiveSink = null;
  }

  Future<void> _reset() async {
    await _closeReceiveSink();
    _fileOffers = null;
    _session = null;
    _closed = false;
  }

  void _closeWithError(Object error) {
    if (_closed) return;
    _closed = true;
    _session = null;
    _fileOffers = null;
    unawaited(_closeReceiveSink());
    onTerminalInput?.call('\r\nZMODEM: $error\r\n');
    Future<void>.delayed(const Duration(milliseconds: 50), () {
      _closed = false;
    });
  }

  void _flush() {
    final data = _session?.dataToSend();
    if (data != null && data.isNotEmpty && !_closed) stdin.add(data);
  }
}
