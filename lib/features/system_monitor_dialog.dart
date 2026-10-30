import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/errors.dart';
import '../app/system_metrics.dart';
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
    ('资源', '__resources__'),
    ('延迟', '__latency__'),
  ];
  static const _resourceCommand =
      "sh -c 'head -1 /proc/stat; grep -E \"^(MemTotal|MemAvailable|MemFree|Buffers|Cached):\" /proc/meminfo'";
  int index = 0;
  final output = <int, String>{};
  final loading = <int>{};
  String? error;
  final latencyHistory = <(DateTime, int)>[];
  final resources = <MonitorSample>[];
  Timer? _sampler;
  ProcSnapshot? _lastProc;
  bool _sampling = false;

  int get latencyIndex => _tabs.indexWhere((tab) => tab.$2 == '__latency__');
  int get resourceIndex => _tabs.indexWhere((tab) => tab.$2 == '__resources__');

  @override
  void initState() {
    super.initState();
    _load();
    _sampler = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_sample()),
    );
  }

  @override
  void dispose() {
    _sampler?.cancel();
    super.dispose();
  }

  void _trimHistory() {
    while (latencyHistory.length > 60) {
      latencyHistory.removeAt(0);
    }
    while (resources.length > 60) {
      resources.removeAt(0);
    }
  }

  void _updateLatencySummary() {
    if (latencyHistory.isEmpty) return;
    final values = latencyHistory.map((entry) => entry.$2).toList();
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final avg = values.reduce((a, b) => a + b) ~/ values.length;
    output[latencyIndex] =
        'SSH 命令往返延迟（最近 5 分钟，${values.length} 次采样）\n\n'
        '最小 $min ms\n最大 $max ms\n平均 $avg ms\n最近 ${values.last} ms\n\n'
        '每 5 秒自动采样一次；打开本页可快速采样 10 次。';
  }

  Future<void> _sample() async {
    if (_sampling || !mounted) return;
    _sampling = true;
    try {
      final watch = Stopwatch()..start();
      await native.runCommand(
        connectionId: widget.connectionId,
        command: 'true',
      );
      watch.stop();
      final now = DateTime.now();
      latencyHistory.add((now, watch.elapsedMilliseconds));
      final raw = await native.runCommand(
        connectionId: widget.connectionId,
        command: _resourceCommand,
      );
      final snapshot = ProcSnapshot.parse(raw);
      if (snapshot != null) {
        resources.add(
          MonitorSample(
            at: now,
            cpuPercent: cpuUsageBetween(_lastProc, snapshot),
            memoryPercent: snapshot.memoryUsedPercent,
          ),
        );
        _lastProc = snapshot;
      }
      _trimHistory();
      _updateLatencySummary();
      if (mounted) setState(() {});
    } catch (_) {
      // Sampling is best-effort; explicit tabs still surface remote errors.
    } finally {
      _sampling = false;
    }
  }

  Future<void> _load() async {
    final current = index;
    setState(() {
      loading.add(current);
      error = null;
    });
    try {
      final command = _tabs[current].$2;
      if (command == '__latency__') {
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
            () =>
                output[current] = '正在采样… ${i + 1}/10\n\n最近 ${samples.last} ms',
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        final now = DateTime.now();
        final average = samples.reduce((a, b) => a + b) ~/ samples.length;
        latencyHistory.add((now, average));
        _trimHistory();
        _updateLatencySummary();
        if (mounted) setState(() {});
        return;
      }
      if (command == '__resources__') {
        await _sample();
        if (mounted && resources.isEmpty) {
          setState(() => error = '无法读取 /proc，远端可能不是 Linux');
        }
        return;
      }
      final result = await native.runCommand(
        connectionId: widget.connectionId,
        command: command,
      );
      if (mounted) setState(() => output[current] = result);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => loading.remove(current));
    }
  }

  Widget _resourceView() {
    final last = resources.isEmpty ? null : resources.last;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xff161c24),
        borderRadius: BorderRadius.circular(8),
      ),
      child: resources.isEmpty
          ? const Center(child: Text('正在通过独立通道采样…'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.memory,
                      size: 16,
                      color: Color(0xff4fd1c5),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'CPU ${formatPercent(last?.cpuPercent)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.storage,
                      size: 16,
                      color: Color(0xff7aa2f7),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '内存 ${formatPercent(last?.memoryPercent)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _PercentChart(
                    label: 'CPU',
                    color: const Color(0xff4fd1c5),
                    values: [for (final sample in resources) sample.cpuPercent],
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _PercentChart(
                    label: '内存',
                    color: const Color(0xff7aa2f7),
                    values: [
                      for (final sample in resources) sample.memoryPercent,
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '每 5 秒采样一次并保留最近 5 分钟，依赖远端 /proc；非 Linux 主机可能无数据。',
                  style: TextStyle(fontSize: 11, color: Color(0xff8b98a8)),
                ),
              ],
            ),
    );
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
          if (index == latencyIndex && latencyHistory.isNotEmpty)
            SizedBox(
              height: 150,
              child: CustomPaint(
                painter: _LatencyPainter([
                  for (final entry in latencyHistory) entry.$2,
                ]),
                child: const SizedBox.expand(),
              ),
            ),
          if (index == resourceIndex)
            Expanded(child: _resourceView())
          else
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
              '计时任务只通过独立 SSH 通道执行只读命令；结果受远端权限和防火墙影响。',
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
    final grid = Paint()
      ..color = const Color(0x22ffffff)
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
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
    final label = TextPainter(
      text: const TextSpan(
        text: '5 分钟前',
        style: TextStyle(fontSize: 10, color: Color(0xff8b98a8)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(2, size.height - label.height));
    final now = TextPainter(
      text: const TextSpan(
        text: '现在',
        style: TextStyle(fontSize: 10, color: Color(0xff8b98a8)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    now.paint(
      canvas,
      Offset(size.width - now.width - 2, size.height - now.height),
    );
  }

  @override
  bool shouldRepaint(covariant _LatencyPainter oldDelegate) =>
      oldDelegate.values != values;
}

class _PercentChart extends StatelessWidget {
  final String label;
  final Color color;
  final List<double?> values;
  const _PercentChart({
    required this.label,
    required this.color,
    required this.values,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: const TextStyle(fontSize: 11)),
      const SizedBox(height: 4),
      Expanded(
        child: CustomPaint(
          painter: _PercentPainter(values, color),
          child: const SizedBox.expand(),
        ),
      ),
    ],
  );
}

class _PercentPainter extends CustomPainter {
  final List<double?> values;
  final Color color;
  const _PercentPainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x22ffffff)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) return;
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..style = PaintingStyle.fill;
    final path = Path();
    final area = Path();
    var started = false;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        started = false;
        continue;
      }
      final x = values.length == 1
          ? size.width / 2
          : i * size.width / (values.length - 1);
      final y = size.height - (value.clamp(0, 100) / 100) * size.height;
      if (!started) {
        path.moveTo(x, y);
        area.moveTo(x, size.height);
        area.lineTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
        area.lineTo(x, y);
      }
    }
    if (started) {
      area.lineTo(size.width, size.height);
      area.close();
      canvas.drawPath(area, fill);
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(covariant _PercentPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
