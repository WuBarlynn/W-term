import '../app/font_catalog.dart';

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
  int get processIndex => _tabs.indexWhere((tab) => tab.$1 == '进程');
  int get dockerIndex => _tabs.indexWhere((tab) => tab.$1 == 'Docker');
  int get portIndex => _tabs.indexWhere((tab) => tab.$1 == '端口');
  final filter = TextEditingController();
  String processSort = 'cpu';
  String portProtocol = 'all';
  bool portLoopbackOnly = false;

  String _commandFor(int tab) {
    if (tab != processIndex) return _tabs[tab].$2;
    final sort = processSort == 'mem' ? '%mem' : '%cpu';
    return "sh -c 'ps -eo pid,ppid,comm,%cpu,%mem --sort=-$sort 2>/dev/null | head -40'";
  }

  String get filteredOutput {
    final raw = output[index];
    if (raw == null) return '尚未获取数据';
    final query = filter.text.trim().toLowerCase();
    if (index != processIndex && index != portIndex) return raw;
    var lines = raw.split('\n');
    if (index == portIndex) {
      if (portProtocol != 'all') {
        lines = lines
            .where((line) => line.toLowerCase().contains(portProtocol))
            .toList();
      }
      if (portLoopbackOnly) {
        lines = lines
            .where(
              (line) =>
                  line.contains('127.0.0.1') ||
                  line.contains('::1') ||
                  line.contains('[::1]'),
            )
            .toList();
      }
    }
    if (query.isEmpty) return lines.join('\n');
    final filtered = lines.where((line) => line.toLowerCase().contains(query));
    return filtered.isEmpty
        ? '没有匹配“${filter.text.trim()}”的行'
        : filtered.join('\n');
  }

  Future<void> dockerAction(String action) async {
    final names = dockerContainerNames(output[dockerIndex] ?? '');
    if (names.isEmpty) {
      setState(() => error = '没有可操作的容器，请先刷新 Docker 列表');
      return;
    }
    String selected = names.first;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(action == 'stop' ? '停止 Docker 容器' : '重启 Docker 容器'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: const InputDecoration(labelText: '容器'),
                items: [
                  for (final name in names)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) =>
                    setDialogState(() => selected = value ?? names.first),
              ),
              const SizedBox(height: 10),
              Text(
                action == 'stop'
                    ? '会立即停止该容器，可能中断正在运行的服务。'
                    : '会重启该容器；短时服务不可用。',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action == 'stop' ? '停止' : '重启'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await native.runCommand(
        connectionId: widget.connectionId,
        command: "sh -c 'docker $action -- $selected'",
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(action == 'stop' ? '已发送停止请求' : '已发送重启请求')),
      );
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  Future<void> copyPid() async {
    final controller = TextEditingController();
    final pid = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('复制 PID'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'PID'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('复制'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    final value = pid?.trim() ?? '';
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(value)) {
      if (value.isNotEmpty && mounted) {
        setState(() => error = 'PID 必须是正整数');
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PID 已复制')));
    }
  }

  Future<void> killProcess() async {
    final controller = TextEditingController();
    final pid = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束远端进程'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'PID',
            helperText: '会先发送 SIGTERM；请确认 PID 对应预期进程',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    final value = pid?.trim() ?? '';
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(value)) {
      if (value.isNotEmpty && mounted) {
        setState(() => error = 'PID 必须是正整数');
      }
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('向 PID $value 发送 SIGTERM？'),
        content: const Text('进程可能不会立即退出，也可能影响正在运行的服务。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('结束进程'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await native.runCommand(
        connectionId: widget.connectionId,
        command: "kill -TERM $value",
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已发送 SIGTERM')));
        await _load();
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

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
    filter.dispose();
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
      final command = _commandFor(current);
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
          if (index == processIndex ||
              index == portIndex ||
              index == dockerIndex)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: filter,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.filter_alt_outlined, size: 18),
                        hintText: '筛选进程或端口',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (index == dockerIndex) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: loading.contains(index)
                          ? null
                          : () => dockerAction('stop'),
                      icon: const Icon(Icons.stop_circle_outlined, size: 16),
                      label: const Text('停止'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: loading.contains(index)
                          ? null
                          : () => dockerAction('restart'),
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('重启'),
                    ),
                  ],
                  if (index == portIndex) ...[
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: portProtocol,
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('全部协议')),
                        DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                        DropdownMenuItem(value: 'udp', child: Text('UDP')),
                      ],
                      onChanged: (value) => setState(
                        () => portProtocol = value ?? 'all',
                      ),
                    ),
                    FilterChip(
                      label: const Text('仅回环'),
                      selected: portLoopbackOnly,
                      onSelected: (value) =>
                          setState(() => portLoopbackOnly = value),
                    ),
                  ],
                  if (index == processIndex) ...[
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: processSort,
                      items: const [
                        DropdownMenuItem(value: 'cpu', child: Text('按 CPU')),
                        DropdownMenuItem(value: 'mem', child: Text('按内存')),
                      ],
                      onChanged: loading.contains(index)
                          ? null
                          : (value) {
                              setState(() => processSort = value ?? 'cpu');
                              _load();
                            },
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: loading.contains(index) ? null : copyPid,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制 PID'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: loading.contains(index) ? null : killProcess,
                      icon: const Icon(Icons.stop_circle_outlined, size: 16),
                      label: const Text('结束 PID'),
                    ),
                  ],
                ],
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
                          filteredOutput,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontFamilyFallback: monoFontFallback,
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
