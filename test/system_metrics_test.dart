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
}
