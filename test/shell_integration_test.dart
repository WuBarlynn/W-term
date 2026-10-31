import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/shell_integration.dart';

void main() {
  test('shell directory integration is a single bash/zsh command', () {
    expect(shellDirectoryIntegrationCommand, contains('BASH_VERSION'));
    expect(shellDirectoryIntegrationCommand, contains('ZSH_VERSION'));
    expect(shellDirectoryIntegrationCommand, contains(r'\033]7;file://'));
    expect(shellDirectoryIntegrationCommand.contains('\n'), isFalse);
    expect(shellDirectoryIntegrationCommand.contains('\x00'), isFalse);
    expect(shellDirectoryIntegrationCommand.length, lessThan(16384));
  });

  test('fish directory integration uses a prompt event', () {
    expect(fishDirectoryIntegrationCommand, contains('--on-event fish_prompt'));
    expect(fishDirectoryIntegrationCommand, contains(r'\033]7;file://'));
    expect(
      shellDirectoryIntegrationCommandFor('fish'),
      fishDirectoryIntegrationCommand,
    );
    expect(
      shellDirectoryIntegrationCommandFor('bash'),
      shellDirectoryIntegrationCommand,
    );
    expect(fishDirectoryIntegrationCommand.contains('\n'), isFalse);
  });

  test('command-finished hooks emit OSC 133;D for every shell', () {
    for (final entry in {
      'bash': bashCommandFinishedIntegrationCommand,
      'zsh': zshCommandFinishedIntegrationCommand,
      'fish': fishCommandFinishedIntegrationCommand,
    }.entries) {
      expect(entry.value, contains(r'\033]133;D;%s\007'));
      expect(entry.value.contains('\n'), isFalse, reason: entry.key);
      expect(shellCommandFinishedIntegrationCommandFor(entry.key), entry.value);
    }
    expect(
      shellCommandFinishedIntegrationCommandFor('unknown'),
      bashCommandFinishedIntegrationCommand,
    );
  });
}
