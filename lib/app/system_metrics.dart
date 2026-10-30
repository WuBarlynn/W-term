/// Parsed `/proc/stat` and `/proc/meminfo` values used by the monitor charts.
class ProcSnapshot {
  final int totalTicks, idleTicks;
  final int? memTotalKb, memAvailableKb;
  const ProcSnapshot({
    required this.totalTicks,
    required this.idleTicks,
    this.memTotalKb,
    this.memAvailableKb,
  });

  double? get memoryUsedPercent {
    final total = memTotalKb;
    final available = memAvailableKb;
    if (total == null || available == null || total <= 0) return null;
    return ((total - available) / total * 100).clamp(0, 100);
  }

  /// Parses the combined output of:
  /// `head -1 /proc/stat; grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached):' /proc/meminfo`
  static ProcSnapshot? parse(String output) {
    int? total, idle;
    int? memTotal, memAvailable, memFree, buffers, cached;
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('cpu ')) {
        final values = line
            .substring(4)
            .trim()
            .split(RegExp(r'\s+'))
            .map(int.tryParse)
            .toList();
        if (values.length < 4 || values.any((value) => value == null)) {
          continue;
        }
        var sum = 0;
        for (final value in values) {
          sum += value!;
        }
        total = sum;
        idle = values[3]! + (values.length > 4 ? values[4]! : 0);
      } else if (line.startsWith('MemTotal:')) {
        memTotal = _kilobytes(line);
      } else if (line.startsWith('MemAvailable:')) {
        memAvailable = _kilobytes(line);
      } else if (line.startsWith('MemFree:')) {
        memFree = _kilobytes(line);
      } else if (line.startsWith('Buffers:')) {
        buffers = _kilobytes(line);
      } else if (line.startsWith('Cached:')) {
        cached = _kilobytes(line);
      }
    }
    if (total == null || idle == null) return null;
    memAvailable ??= memFree == null
        ? null
        : memFree + (buffers ?? 0) + (cached ?? 0);
    return ProcSnapshot(
      totalTicks: total,
      idleTicks: idle,
      memTotalKb: memTotal,
      memAvailableKb: memAvailable,
    );
  }

  static int? _kilobytes(String line) {
    final match = RegExp(r':\s*(\d+)').firstMatch(line);
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}

double? cpuUsageBetween(ProcSnapshot? previous, ProcSnapshot current) {
  if (previous == null) return null;
  final total = current.totalTicks - previous.totalTicks;
  final idle = current.idleTicks - previous.idleTicks;
  if (total <= 0 || idle < 0) return null;
  return ((total - idle) / total * 100).clamp(0, 100);
}

class MonitorSample {
  final DateTime at;
  final double? cpuPercent, memoryPercent;
  const MonitorSample({required this.at, this.cpuPercent, this.memoryPercent});
}

String formatPercent(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)}%';
