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

  test('private IPv4 scopes resolve locally without network', () async {
    expect(localIpv4Label('192.168.1.8'), '局域网地址');
    expect(localIpv4Label('10.0.0.2'), '局域网地址');
    expect(localIpv4Label('172.20.1.1'), '局域网地址');
    expect(localIpv4Label('127.0.0.1'), '本机回环地址');
    expect(localIpv4Label('169.254.10.1'), '链路本地地址');
    expect(localIpv4Label('100.64.0.1'), '运营商级 NAT 地址');
    expect(localIpv4Label('8.8.8.8'), isNull);
    final result = await lookupIp('127.0.0.1');
    expect(result.local, isTrue);
    expect(result.country, '本机回环地址');
    expect(result.cached, isFalse);
  });

  test('JSON detection accepts objects and arrays only', () {
    expect(isJsonText('{"a":1}'), isTrue);
    expect(isJsonText(' [1, 2, 3] '), isTrue);
    expect(isJsonText('[]'), isTrue);
    expect(isJsonText('{"a":}'), isFalse);
    expect(isJsonText('42'), isFalse);
    expect(isJsonText('"text"'), isFalse);
    expect(isJsonText(''), isFalse);
    expect(isJsonText('ls -la'), isFalse);
  });

  test(
    'IP lookup cache persists fresh entries and falls back to stale',
    () async {
      final dir = await Directory.systemTemp.createTemp('wterm-ip-cache-');
      final file = File('${dir.path}/ip-cache.json');
      var now = DateTime.utc(2026, 11, 1, 12);
      const result = IpLookupResult(
        country: 'China',
        region: 'Zhejiang',
        city: 'Hangzhou',
        isp: 'Example ISP',
        org: 'Example Org',
        timezone: 'Asia/Shanghai',
        asn: '64512',
        latitude: 30.2741,
        longitude: 120.1551,
      );
      try {
        final cache = IpLookupCache(file: () async => file, now: () => now);
        await cache.write('1.2.3.4', result);
        final fresh = await cache.read('1.2.3.4');
        expect(fresh?.city, 'Hangzhou');
        expect(fresh?.asn, '64512');
        expect(fresh?.latitude, 30.2741);
        expect(fresh?.cached, isTrue);
        expect(fresh?.stale, isFalse);

        final restored = IpLookupCache(file: () async => file, now: () => now);
        expect((await restored.read('1.2.3.4'))?.country, 'China');
        expect((await restored.read('1.2.3.4'))?.longitude, 120.1551);

        now = now.add(const Duration(hours: 25));
        expect(await restored.read('1.2.3.4'), isNull);
        final stale = await restored.read('1.2.3.4', includeStale: true);
        expect(stale?.stale, isTrue);
        expect(stale?.isp, 'Example ISP');
        expect(await restored.read('not-an-ip', includeStale: true), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'IP lookup cache ignores corrupt files and prunes oldest entries',
    () async {
      final dir = await Directory.systemTemp.createTemp('wterm-ip-cache-');
      final file = File('${dir.path}/ip-cache.json');
      var now = DateTime.utc(2026, 11, 1, 12);
      IpLookupResult result(String city) => IpLookupResult(
        country: 'CN',
        region: '',
        city: city,
        isp: '',
        org: '',
        timezone: '',
      );
      try {
        await file.writeAsString('{broken');
        final cache = IpLookupCache(
          file: () async => file,
          now: () => now,
          maxEntries: 2,
        );
        expect(await cache.read('1.1.1.1'), isNull);
        await cache.write('1.1.1.1', result('A'));
        now = now.add(const Duration(minutes: 1));
        await cache.write('2.2.2.2', result('B'));
        now = now.add(const Duration(minutes: 1));
        await cache.write('3.3.3.3', result('C'));

        final restored = IpLookupCache(
          file: () async => file,
          now: () => now,
          maxEntries: 2,
        );
        expect(await restored.read('1.1.1.1'), isNull);
        expect((await restored.read('2.2.2.2'))?.city, 'B');
        expect((await restored.read('3.3.3.3'))?.city, 'C');

        await restored.clear();
        expect(await restored.read('2.2.2.2'), isNull);
        expect(await file.exists(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

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
    expect(isSystemPreviewPath('/tmp/a.pdf'), isTrue);
    expect(isSystemPreviewPath('/tmp/a.MP4'), isTrue);
    expect(isSystemPreviewPath('/tmp/a.txt'), isFalse);
  });

  test('plugin switches persist', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-plugins-');
    final file = File('${dir.path}/plugins.json');
    try {
      final store = PluginSettings(file: () async => file);
      await store.load();
      expect(store.jsonFormatter, isTrue);
      expect(store.windowsHardwareInput, isFalse);
      expect(store.dragUpload, isTrue);
      expect(store.compactTabs, isFalse);
      expect(store.showFavoritesBar, isTrue);
      expect(store.clickTabLocates, isFalse);
      expect(store.restoreLayout, isTrue);
      expect(store.showStatusBar, isTrue);
      expect(store.rightClickPaste, isFalse);
      expect(store.showComposeBar, isFalse);
      expect(store.selectionPin, isTrue);
      expect(store.selectionSnippet, isTrue);
      expect(store.selectionShare, isTrue);
      expect(store.selectionMenu, isTrue);
      expect(store.notificationThresholdSeconds, 15);
      expect(store.maxUploadSizeMb, 0);
      expect(uploadTooLarge(101 * 1024 * 1024, 100), isTrue);
      expect(uploadTooLarge(100 * 1024 * 1024, 100), isFalse);
      expect(uploadTooLarge(5000, 0), isFalse);
      await store.save(
        json: false,
        ip: true,
        preview: false,
        completion: false,
        notifications: false,
        windowsHardwareInputNext: true,
        dragUploadNext: false,
        compactTabsNext: true,
        showFavoritesBarNext: false,
        clickTabLocatesNext: true,
        restoreLayoutNext: false,
        showStatusBarNext: false,
        rightClickPasteNext: true,
        showComposeBarNext: true,
        selectionPinNext: false,
        selectionSnippetNext: false,
        selectionShareNext: false,
        selectionMenuNext: false,
        notificationThresholdSecondsNext: 60,
        maxUploadSizeMbNext: 500,
      );
      final restored = PluginSettings(file: () async => file);
      await restored.load();
      expect(restored.jsonFormatter, isFalse);
      expect(restored.ipLookup, isTrue);
      expect(restored.filePreview, isFalse);
      expect(restored.commandCompletion, isFalse);
      expect(restored.taskNotifications, isFalse);
      expect(restored.windowsHardwareInput, isTrue);
      expect(restored.dragUpload, isFalse);
      expect(restored.compactTabs, isTrue);
      expect(restored.showFavoritesBar, isFalse);
      expect(restored.clickTabLocates, isTrue);
      expect(restored.restoreLayout, isFalse);
      expect(restored.showStatusBar, isFalse);
      expect(restored.rightClickPaste, isTrue);
      expect(restored.showComposeBar, isTrue);
      expect(restored.selectionPin, isFalse);
      expect(restored.selectionSnippet, isFalse);
      expect(restored.selectionShare, isFalse);
      expect(restored.selectionMenu, isFalse);
      expect(restored.notificationThresholdSeconds, 60);
      expect(restored.maxUploadSizeMb, 500);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
