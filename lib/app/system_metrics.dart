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

class NetworkCounters {
  final Map<String, (int rx, int tx)> interfaces;
  const NetworkCounters(this.interfaces);

  /// Parses Linux `/proc/net/dev`; loopback and malformed lines are ignored.
  static NetworkCounters parse(String output) {
    final values = <String, (int, int)>{};
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final name = line.substring(0, separator).trim();
      if (name.isEmpty || name == 'lo') continue;
      final fields = line
          .substring(separator + 1)
          .trim()
          .split(RegExp(r'\s+'));
      if (fields.length < 9) continue;
      final rx = int.tryParse(fields[0]);
      final tx = int.tryParse(fields[8]);
      if (rx == null || tx == null || rx < 0 || tx < 0) continue;
      values[name] = (rx, tx);
    }
    return NetworkCounters(values);
  }

  /// Returns one line per interface with positive deltas.
  String ratesSince(NetworkCounters previous, Duration elapsed) {
    final millis = elapsed.inMilliseconds.clamp(200, 60000);
    final lines = <String>[];
    for (final entry in interfaces.entries) {
      final before = previous.interfaces[entry.key];
      if (before == null) continue;
      final rx = entry.value.$1 - before.$1;
      final tx = entry.value.$2 - before.$2;
      if (rx < 0 || tx < 0 || (rx == 0 && tx == 0)) continue;
      lines.add(
        '${entry.key}  ↓ ${_rate(rx, millis)}  ↑ ${_rate(tx, millis)}',
      );
    }
    return lines.join('\n');
  }

  static String _rate(int bytes, int millis) {
    final perSecond = bytes * 1000 / millis;
    if (perSecond >= 1024 * 1024) {
      return '${(perSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (perSecond >= 1024) {
      return '${(perSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${perSecond.toStringAsFixed(0)} B/s';
  }
}

class HostMetrics {
  final double? load1;
  final int? diskUsedPercent;
  const HostMetrics({this.load1, this.diskUsedPercent});
  /// Parses `cat /proc/loadavg` or `sysctl -n vm.loadavg` plus `df -P /`.
  static HostMetrics? parse(String output) {
    double? load;
    int? disk;
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('{') && line.endsWith('}')) {
        final fields = line
            .substring(1, line.length - 1)
            .trim()
            .split(RegExp(r'\s+'));
        load ??= _load(fields.first);
      } else if (RegExp(r'^\d+(\.\d+)?\s+\d+(\.\d+)?\s+\d+(\.\d+)?')
          .hasMatch(line)) {
        load ??= _load(line.split(RegExp(r'\s+')).first);
      }
      final capacity = RegExp(r'\s(\d{1,3})%\s').firstMatch(line);
      if (capacity != null) {
        final value = int.tryParse(capacity.group(1)!);
        if (value != null && value <= 100) disk ??= value;
      }
    }
    if (load == null && disk == null) return null;
    return HostMetrics(load1: load, diskUsedPercent: disk);
  }

  static double? _load(String value) {
    final parsed = double.tryParse(value);
    return parsed == null || parsed < 0 || parsed > 100000 ? null : parsed;
  }
}

String formatPercent(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)}%';

/// Container names from `docker ps --format "table {{.Names}}\t..."`.
List<String> dockerContainerNames(String output) {
  final names = <String>[];
  final seen = <String>{};
  for (final line in output.split('\n')) {
    final value = line.trim();
    if (value.isEmpty || !value.contains('\t')) continue;
    final first = value.split(RegExp(r'\s+')).first;
    if (first.toUpperCase() == 'NAMES' || first.toUpperCase() == 'CONTAINER') {
      continue;
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(first)) {
      continue;
    }
    if (seen.add(first)) names.add(first);
    if (names.length >= 100) break;
  }
  return names;
}
