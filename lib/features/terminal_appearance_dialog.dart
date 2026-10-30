import 'package:flutter/material.dart';

import '../app/terminal_appearance.dart';
import '../app/errors.dart';

class TerminalAppearanceDialog extends StatefulWidget {
  final TerminalAppearance store;
  const TerminalAppearanceDialog({super.key, required this.store});
  @override
  State<TerminalAppearanceDialog> createState() =>
      _TerminalAppearanceDialogState();
}

class _TerminalAppearanceDialogState extends State<TerminalAppearanceDialog> {
  late String palette = widget.store.palette;
  late int size = widget.store.fontSize;
  late String uiTheme = widget.store.uiTheme;
  bool busy = false;
  String? error;
  Future<void> save() async {
    setState(() => busy = true);
    try {
      await widget.store.save(palette, size, nextUiTheme: uiTheme);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = TerminalAppearance.themeFor(palette);
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        scrollable: true,
        title: const Text('终端外观'),
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: palette,
                decoration: const InputDecoration(labelText: '终端配色'),
                items: [
                  for (final entry in TerminalAppearance.names.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => palette = value ?? 'dark'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: uiTheme,
                decoration: const InputDecoration(labelText: '界面主题'),
                items: const [
                  DropdownMenuItem(value: 'system', child: Text('跟随系统')),
                  DropdownMenuItem(value: 'dark', child: Text('深色')),
                  DropdownMenuItem(value: 'light', child: Text('浅色')),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => uiTheme = value ?? 'system'),
              ),
              const SizedBox(height: 20),
              Text('字号：$size'),
              Slider(
                min: 10,
                max: 28,
                divisions: 18,
                value: size.toDouble(),
                label: '$size',
                onChanged: busy
                    ? null
                    : (v) => setState(() => size = v.round()),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                color: theme.background,
                child: Text(
                  'user@server ~ %\n连接成功 · Hello, terminal!',
                  style: TextStyle(
                    color: theme.foreground,
                    fontSize: size.toDouble(),
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('应用到所有会话，并在本机保存。', style: TextStyle(fontSize: 12)),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? '保存中…' : '应用'),
          ),
        ],
      ),
    );
  }
}
