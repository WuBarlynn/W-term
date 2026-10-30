import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/plugins.dart';

void main() {
  test('IPv4 validation accepts only four valid octets', () {
    expect(isIpv4('192.168.1.1'), isTrue);
    expect(isIpv4('0.0.0.0'), isTrue);
    expect(isIpv4('255.255.255.255'), isTrue);
    expect(isIpv4('256.1.1.1'), isFalse);
    expect(isIpv4('1.2.3'), isFalse);
    expect(isIpv4('1.2.3.a'), isFalse);
    expect(isIpv4(''), isFalse);
  });

  test('preview path resolution and image detection', () {
    expect(
      resolveRemotePath('/var/log/app.log', '/home/a'),
      '/var/log/app.log',
    );
    expect(
      resolveRemotePath('screenshot.PNG', '/home/a/'),
      '/home/a/screenshot.PNG',
    );
    expect(resolveRemotePath('a.txt', null), isNull);
    expect(resolveRemotePath('a\nb.txt', '/tmp'), isNull);
    expect(isImagePath('/tmp/a.webp'), isTrue);
    expect(isImagePath('/tmp/a.log'), isFalse);
  });

  test('plugin switches persist', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-plugins-');
    final file = File('${dir.path}/plugins.json');
    try {
      final store = PluginSettings(file: () async => file);
      await store.load();
      expect(store.jsonFormatter, isTrue);
      await store.save(
        json: false,
        ip: true,
        preview: false,
        completion: false,
      );
      final restored = PluginSettings(file: () async => file);
      await restored.load();
      expect(restored.jsonFormatter, isFalse);
      expect(restored.ipLookup, isTrue);
      expect(restored.filePreview, isFalse);
      expect(restored.commandCompletion, isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
