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
}
