import 'dart:convert';
import 'dart:typed_data';

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

  test('imports Xshell xsh sessions', () {
    final hosts = parseHostImport(
      'ops.xsh',
      '[XSH SESSION]\r\nVersion=5.1\r\n\r\n[CONNECTION]\r\n'
          'Protocol=SSH\r\nHost=ops.example.com\r\nPort=2222\r\n'
          'UserName=deploy\r\nName=Ops gateway\r\n\r\n'
          '[CONNECTION:AUTHENTICATION]\r\nPassword=encrypted-value\r\n',
    );
    expect(hosts.single.name, 'Ops gateway');
    expect(hosts.single.host, 'ops.example.com');
    expect(hosts.single.username, 'deploy');
    expect(hosts.single.port, 2222);
  });

  test('imports Xshell xts backup archives', () {
    final bytes = base64Decode(
      'UEsDBBQAAAAIABwIX10ybuN/jwAAAK8AAAAMAAAAUHJvZC9vcHMueHNoXY1BCoMwEEX3A3MH'
      'TyC00E0hCwlC3MRCtBSki6CDCOqETMB6+0pLN327z/vwuoczmSudq2r7RLhTlIlXdclPCAid'
      'rq0tdfOVt8iJe56VcwbBsCTFQXJ6+SXMlPe8HB+OSZ0PEFqhaP1CaqAw847wGXWQbPSJNr//'
      'Fa5F25jSNpUufkEvsnEc1DSuHGlAeANQSwMEFAAAAAgAHAhfXYdy4LQLAAAACQAAABAAAABO'
      'b3Rlcy9yZWFkbWUudHh0y0zPyy9KVchNBQBQSwECFAMUAAAACAAcCF9dMm7jf48AAACvAAAA'
      'DAAAAAAAAAAAAAAAgAEAAAAAUHJvZC9vcHMueHNoUEsBAhQDFAAAAAgAHAhfXYdy4LQLAAAA'
      'CQAAABAAAAAAAAAAAAAAAIABuQAAAE5vdGVzL3JlYWRtZS50eHRQSwUGAAAAAAIAAgB4AAAA'
      '8gAAAAAA',
    );
    final hosts = parseHostImportBytes('backup.xts', Uint8List.fromList(bytes));
    expect(hosts.single.host, 'ops.example.com');
    expect(hosts.single.username, 'deploy');
    expect(hosts.single.group, 'Prod');
    expect(hosts.single.port, 2222);
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
