import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/zmodem_mux.dart';
import 'package:xterm/zmodem.dart';

bool _has(String program) {
  if (Platform.isWindows) return false;
  final result = Process.runSync('which', [program]);
  return result.exitCode == 0;
}

List<int> _payload() => List<int>.generate(80000, (i) => i % 251);

Future<void> _waitUntil(bool Function() test) async {
  for (var i = 0; i < 300; i++) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('ZMODEM test timed out');
}

void main() {
  test('receives a file from lrzsz sz', () async {
    final source = File(
      '${Directory.systemTemp.path}/wterm-zmodem-${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    final bytes = _payload();
    await source.writeAsBytes(bytes);
    final process = await Process.start('sz', [source.path]);
    final received = BytesBuilder();
    var accepted = false;
    final mux = WTermZModemMux(
      stdout: process.stdout.map(Uint8List.fromList),
      stdin: process.stdin,
    );
    mux.onFileOffer = (offer) async {
      accepted = true;
      await for (final chunk in offer.accept(0)) {
        received.add(chunk);
      }
    };
    await process.exitCode.timeout(const Duration(seconds: 20));
    await _waitUntil(() => accepted && received.length == bytes.length);
    mux.onFileOffer = null;
    process.kill();
    await source.delete();
    expect(received.length, bytes.length);
    expect(received.takeBytes(), bytes);
  }, skip: !_has('sz'));

  test('sends a file to lrzsz rz', () async {
    final dir = Directory.systemTemp.createTempSync('wterm-zmodem-recv');
    final bytes = _payload();
    final process = await Process.start('rz', ['-y'], workingDirectory: dir.path);
    final mux = WTermZModemMux(
      stdout: process.stdout.map(Uint8List.fromList),
      stdin: process.stdin,
    );
    mux.onFileRequest = () async => [
      ZModemCallbackOffer(
        ZModemFileInfo(pathname: 'payload.bin', length: bytes.length),
        onAccept: (offset) => Stream.value(
          Uint8List.fromList(bytes.sublist(offset)),
        ),
      ),
    ];
    await process.exitCode.timeout(const Duration(seconds: 20));
    final target = File('${dir.path}/payload.bin');
    await _waitUntil(() => target.existsSync() && target.lengthSync() == bytes.length);
    mux.onFileRequest = null;
    process.kill();
    final got = await target.readAsBytes();
    dir.deleteSync(recursive: true);
    expect(got.length, bytes.length);
    expect(got, bytes);
  }, skip: !_has('rz'));
}
