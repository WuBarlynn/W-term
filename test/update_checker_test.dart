import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/update_checker.dart';

void main() {
  test('version comparison handles v-prefix and build metadata', () {
    expect(isNewerVersion('v1.0.3', '1.0.2'), isTrue);
    expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
    expect(isNewerVersion('v1.0.2', '1.0.2'), isFalse);
    expect(isNewerVersion('1.0.1', '1.0.2'), isFalse);
    expect(isNewerVersion('v2.0.0+9', '1.99.99'), isTrue);
  });

  test('update asset selection follows the desktop platform', () {
    const info = UpdateInfo(
      version: 'v1.0.4',
      url: 'https://example.com',
      notes: '',
      assets: [
        UpdateAsset('a.dmg', 'https://example.com/a.dmg'),
        UpdateAsset('a.exe', 'https://example.com/a.exe'),
        UpdateAsset('a.ipa', 'https://example.com/a.ipa'),
      ],
    );
    expect(info.assetFor('macos')?.name, 'a.dmg');
    expect(info.assetFor('windows')?.name, 'a.exe');
    expect(info.assetFor('ios'), isNull);
  });

  test('release JSON exposes downloadable desktop assets', () {
    final info = parseUpdateRelease({
      'tag_name': 'v9.9.9',
      'html_url': 'https://github.com/WuBarlynn/W-term/releases/tag/v9.9.9',
      'body': 'notes',
      'assets': [
        {
          'name': 'W-Term-9.9.9-macos.dmg',
          'browser_download_url': 'https://example.com/app.dmg',
        },
        {
          'name': 'W-Term-9.9.9-windows.exe',
          'browser_download_url': 'https://example.com/app.exe',
        },
        {
          'name': 'SHA256SUMS.txt',
          'browser_download_url': 'https://example.com/SHA256SUMS.txt',
        },
      ],
    });
    expect(info, isNotNull);
    expect(info!.version, 'v9.9.9');
    expect(info.assetFor('macos')?.name, 'W-Term-9.9.9-macos.dmg');
    expect(info.assetFor('windows')?.name, 'W-Term-9.9.9-windows.exe');
    expect(info.assetFor('ios'), isNull);
    expect(info.checksumAsset?.name, 'SHA256SUMS.txt');
    expect(parseUpdateRelease({'tag_name': 'v1.0.0'}), isNull);
  });

  test('checksum asset and SHA256SUMS parsing are strict', () {
    const info = UpdateInfo(
      version: 'v1.0.8',
      url: 'https://example.com',
      notes: '',
      assets: [
        UpdateAsset('a.dmg', 'https://example.com/a.dmg'),
        UpdateAsset('SHA256SUMS.txt', 'https://example.com/SHA256SUMS.txt'),
      ],
    );
    expect(info.checksumAsset?.name, 'SHA256SUMS.txt');
    const digest =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final content =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  other.zip\n'
        '$digest  a.dmg\n';
    expect(parseUpdateChecksum(content, 'a.dmg'), digest);
    expect(parseUpdateChecksum(content, 'missing.dmg'), isNull);
    expect(parseUpdateChecksum('not a checksum', 'a.dmg'), isNull);
    expect(parseUpdateChecksum('abc  a.dmg', 'a.dmg'), isNull);
  });

  test('Windows installer runs silently and restarts the app', () {
    expect(updateInstallerArguments, contains('/VERYSILENT'));
    expect(updateInstallerArguments, contains('/SUPPRESSMSGBOXES'));
    expect(updateInstallerArguments, contains('/CLOSEAPPLICATIONS'));
    expect(updateInstallerArguments, contains('/RESTARTAPPLICATIONS'));
  });

  test('build-time version constant matches pubspec', () {
    final lines = File('pubspec.yaml').readAsLinesSync();
    final version = lines
        .firstWhere((line) => line.startsWith('version:'))
        .split(':')[1]
        .trim();
    expect(version, '$appVersion+$appBuild');
  });
}
