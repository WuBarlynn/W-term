import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/host_csv.dart';

void main() {
  test('CSV import reads headers, quotes, folders and tags', () {
    final hosts = parseHostCsv(
      '\ufeffname,host,port,username,group,tags\n'
      '"生产, A",example.com,2222,root,Prod,"api,web"\n'
      'db,db.example.com,,admin,Data,db\n',
    );
    expect(hosts.length, 2);
    expect(hosts.first.name, '生产, A');
    expect(hosts.first.port, 2222);
    expect(hosts.first.group, 'Prod');
    expect(hosts.first.tags, ['api', 'web']);
    expect(hosts.last.port, 22);
    expect(hosts.last.username, 'admin');
  });

  test('CSV import rejects missing hosts and invalid ports', () {
    expect(
      () => parseHostCsv('name,host,port,username\nx,,22,u'),
      throwsFormatException,
    );
    expect(
      () => parseHostCsv('name,host,port,username\nx,h,70000,u'),
      throwsFormatException,
    );
  });
}
