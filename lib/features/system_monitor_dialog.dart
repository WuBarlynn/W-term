import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/errors.dart';
import '../src/rust/api/client.dart' as native;

class SystemMonitorDialog extends StatefulWidget {
  final String connectionId, title;
  const SystemMonitorDialog({
    super.key,
    required this.connectionId,
    required this.title,
  });
  @override
  State<SystemMonitorDialog> createState() => _SystemMonitorDialogState();
}

class _SystemMonitorDialogState extends State<SystemMonitorDialog> {
  static const _tabs = <(String, String)>[
    (
      '概览',
      "sh -c 'uname -srm; echo; uptime; echo; (free -m 2>/dev/null || vm_stat); echo; df -h / 2>/dev/null; echo; (cat /proc/loadavg 2>/dev/null)'",
    ),
    (
      '进程',
      "sh -c 'ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -30'",
    ),
    (
      '端口',
      "sh -c '(ss -ltnup 2>/dev/null || netstat -ltnup 2>/dev/null) | head -80'",
    ),
    (
      'Docker',
      "sh -c 'docker ps --format \"table {{.Names}}\\t{{.Image}}\\t{{.Status}}\" 2>&1 | head -50'",
    ),
    ('tmux', "sh -c 'tmux list-sessions 2>&1'"),
    ('延迟', '__latency__'),
  ];
  int index = 0;
  final output = <int, String>{};
  final loading = <int>{};
  String? error;
  final latencies = <int>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final current = index;
    setState(() {
      loading.add(current);
      error = null;
    });
    try {
      if (_tabs[current].$2 == '__latency__') {
        final samples = <int>[];
        for (var i = 0; i < 10; i++) {
          final watch = Stopwatch()..start();
          await native.runCommand(
            connectionId: widget.connectionId,
            command: 'true',
          );
          watch.stop();
          samples.add(watch.elapsedMilliseconds);
          if (!mounted) return;
          setState(
            () => latencies
              ..clear()
              ..addAll(samples),
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        if (!mounted) return;
        final min = samples.reduce((a, b) => a < b ? a : b);
        final max = samples.reduce((a, b) => a > b ? a : b);
        final avg = samples.reduce((a, b) => a + b) ~/ samples.length;
        setState(() {
          output[current] =
              'SSH 命令往返延迟（10 次采样）\n\n最小 $min ms\n最大 $max ms\n平均 $avg ms';
        });
        return;
      }
      final result = await native.runCommand(
        connectionId: widget.connectionId,
        command: _tabs[current].$2,
      );
      if (mounted) setState(() => output[current] = result);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => loading.remove(current));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('系统监控 · ${widget.title}'),
    content: SizedBox(
      width: 780,
      height: 560,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<int>(
                    segments: [
                      for (var i = 0; i < _tabs.length; i++)
                        ButtonSegment(value: i, label: Text(_tabs[i].$1)),
                    ],
                    selected: {index},
                    onSelectionChanged: (value) {
                      setState(() => index = value.first);
                      if (!output.containsKey(index)) _load();
                    },
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: loading.contains(index) ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '复制结果',
                onPressed: output[index] == null
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: output[index]!),
                      ),
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (index == _tabs.length - 1 && latencies.isNotEmpty)
            SizedBox(
              height: 150,
              child: CustomPaint(
                painter: _LatencyPainter(latencies),
                child: const SizedBox.expand(),
              ),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xff161c24),
                borderRadius: BorderRadius.circular(8),
              ),
              child: loading.contains(index)
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      child: SelectableText(
                        output[index] ?? '尚未获取数据',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Color(0xffd3d8df),
                          height: 1.45,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '只在打开或刷新时通过独立 SSH 通道执行只读命令；结果受远端权限和防火墙影响。',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class _LatencyPainter extends CustomPainter {
  final List<int> values;
  const _LatencyPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final max = values.reduce((a, b) => a > b ? a : b).clamp(1, 100000);
    final line = Paint()
      ..color = const Color(0xff4fd1c5)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = const Color(0x334fd1c5)
      ..style = PaintingStyle.fill;
    final path = Path();
    final area = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : i * size.width / (values.length - 1);
      final y = size.height - (values[i] / max) * (size.height - 12) - 6;
      if (i == 0) {
        path.moveTo(x, y);
        area.moveTo(x, size.height);
        area.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        area.lineTo(x, y);
      }
    }
    area.lineTo(size.width, size.height);
    area.close();
    canvas.drawPath(area, fill);
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant _LatencyPainter oldDelegate) =>
      oldDelegate.values != values;
}
