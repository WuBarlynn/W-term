import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/system_metrics.dart';

void main() {
  const sample = '''
cpu  100 0 50 850 0 0 0 0 0 0
MemTotal:       2048000 kB
MemFree:         200000 kB
MemAvailable:   1024000 kB
Buffers:          10000 kB
Cached:          300000 kB
''';

  test('proc snapshot parses CPU ticks and memory', () {
    final snapshot = ProcSnapshot.parse(sample);
    expect(snapshot, isNotNull);
    expect(snapshot!.totalTicks, 1000);
    expect(snapshot.idleTicks, 850);
    expect(snapshot.memTotalKb, 2048000);
    expect(snapshot.memAvailableKb, 1024000);
    expect(snapshot.memoryUsedPercent, closeTo(50, 0.01));
  });

  test('CPU usage uses the delta between two snapshots', () {
    final previous = ProcSnapshot.parse(sample)!;
    const next = '''
cpu  120 0 60 1020 0 0 0 0 0 0
MemTotal:       2048000 kB
MemAvailable:    512000 kB
''';
    final current = ProcSnapshot.parse(next)!;
    expect(current.totalTicks, 1200);
    expect(current.idleTicks, 1020);
    expect(cpuUsageBetween(previous, current), closeTo(15, 0.01));
    expect(cpuUsageBetween(null, current), isNull);
    expect(current.memoryUsedPercent, closeTo(75, 0.01));
  });

  test('MemFree is used when MemAvailable is unavailable', () {
    final snapshot = ProcSnapshot.parse('''
cpu  1 0 1 8 0 0 0 0 0 0
MemTotal:       1000 kB
MemFree:         200 kB
Buffers:          100 kB
Cached:           200 kB
''');
    expect(snapshot!.memAvailableKb, 500);
    expect(snapshot.memoryUsedPercent, closeTo(50, 0.01));
  });

  test('malformed output is rejected instead of throwing', () {
    expect(ProcSnapshot.parse(''), isNull);
    expect(ProcSnapshot.parse('cpu nope\nMemTotal: 1 kB'), isNull);
  });

  test('host metrics parse Linux load and disk usage', () {
    const output = '0.42 0.38 0.35 1/234 5678\n'
        '/dev/disk1s1 488245288 302794220 183932068 63% /\n';
    final metrics = HostMetrics.parse(output);
    expect(metrics, isNotNull);
    expect(metrics!.load1, 0.42);
    expect(metrics.diskUsedPercent, 63);
  });

  test('host metrics parse macOS load average and reject garbage', () {
    const output = '{ 1.23 1.45 1.67 }\n'
        'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        '/dev/disk3s1 971350180 174843032 634721320 22% /\n';
    final metrics = HostMetrics.parse(output);
    expect(metrics!.load1, 1.23);
    expect(metrics.diskUsedPercent, 22);
    expect(HostMetrics.parse('not metrics'), isNull);
    expect(HostMetrics.parse('999% /'), isNull);
  });

  test('network counters parse interfaces and compute rates', () {
    const before = '''
lo: 999 0 0 0 0 0 0 0 999 0 0 0 0 0 0 0
eth0: 1000 1 0 0 0 0 0 0 200 1 0 0 0 0 0 0
''';
    const after = '''
lo: 1999 0 0 0 0 0 0 0 1999 0 0 0 0 0 0 0
eth0: 3048 2 0 0 0 0 0 0 1224 2 0 0 0 0 0 0
''';
    final first = NetworkCounters.parse(before);
    final second = NetworkCounters.parse(after);
    expect(first.interfaces.keys, ['eth0']);
    final rates = second.ratesSince(
      first,
      const Duration(milliseconds: 1000),
    );
    expect(rates, contains('eth0'));
    expect(rates, contains('2.0 KB/s'));
    expect(rates, contains('1.0 KB/s'));
    expect(NetworkCounters.parse('garbage'), isA<NetworkCounters>());
  });

  test('docker container names are parsed and validated', () {
    const output = 'NAMES\tIMAGE\tSTATUS\n'
        'web-1\tnginx:latest\tUp 2 hours\n'
        'db.primary\tpostgres:16\tUp 2 hours\n'
        'bad;name\timage\tUp\n';
    expect(dockerContainerNames(output), ['web-1', 'db.primary']);
    expect(dockerContainerNames('Cannot connect to the Docker daemon'), isEmpty);
  });
}
