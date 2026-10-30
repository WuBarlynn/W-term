import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_import.dart';

void main() {
  test('imports PuTTY registry sessions', () {
    final hosts = parseHostImport(
      'sessions.reg',
      'Windows Registry Editor Version 5.00\n\n'
          '[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\Prod]\n'
          '"HostName"="example.com"\n'
          '"UserName"="root"\n'
          '"PortNumber"=dword:00000016\n',
    );
    expect(hosts.single.name, 'Prod');
    expect(hosts.single.host, 'example.com');
    expect(hosts.single.username, 'root');
    expect(hosts.single.port, 22);
  });

  test('imports MobaXterm bookmark entries', () {
    final hosts = parseHostImport(
      'MobaXterm.ini',
      '[Bookmarks]\n'
          'Prod=#109#0%example.com%2222%root%-1%-1%%%22%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#Example#0\n',
    );
    expect(hosts.single.name, 'Prod');
    expect(hosts.single.host, 'example.com');
    expect(hosts.single.port, 2222);
    expect(hosts.single.username, 'root');
  });

  test('imports SecureCRT INI sessions', () {
    final hosts = parseHostImport(
      'SecureCRT.ini',
      '[Sessions:Database]\n'
          'D:"Hostname"="db.example.com"\n'
          'D:"Username"="admin"\n'
          'D:"Port"=dword:00000016\n',
    );
    expect(hosts.single.name, 'Database');
    expect(hosts.single.host, 'db.example.com');
    expect(hosts.single.username, 'admin');
    expect(hosts.single.port, 22);
  });
}
