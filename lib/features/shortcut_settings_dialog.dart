import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/shortcuts.dart';

class ShortcutSettingsDialog extends StatefulWidget {
  const ShortcutSettingsDialog({super.key});

  @override
  State<ShortcutSettingsDialog> createState() => _ShortcutSettingsDialogState();
}

class _ShortcutSettingsDialogState extends State<ShortcutSettingsDialog> {
  bool saving = false;

  Future<void> record(ShortcutAction action) async {
    final binding = await showDialog<ShortcutKey>(
      context: context,
      builder: (_) => _ShortcutRecorder(action: action),
    );
    if (binding == null) return;
    setState(() => saving = true);
    try {
      await shortcutSettings.set(action.id, binding);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> reset() async {
    setState(() => saving = true);
    try {
      await shortcutSettings.reset();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: shortcutSettings,
    builder: (context, _) => AlertDialog(
      scrollable: true,
      title: const Text('快捷键'),
      content: SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('主修饰键固定；点击录制后按下新的组合键。Esc 取消，禁用后不再触发。'),
            const SizedBox(height: 8),
            for (final action in shortcutActions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(action.label),
                subtitle: Text(
                  shortcutSettings.bindings[action.id]?.label(
                        apple: shortcutSettings.apple,
                      ) ??
                      '未设置',
                ),
                leading: Switch(
                  value: shortcutSettings.bindings[action.id]?.enabled ?? false,
                  onChanged: saving
                      ? null
                      : (value) async {
                          final current = shortcutSettings.bindings[action.id];
                          if (current == null) return;
                          setState(() => saving = true);
                          try {
                            await shortcutSettings.set(
                              action.id,
                              ShortcutKey(
                                keyId: current.keyId,
                                meta: current.meta,
                                control: current.control,
                                shift: current.shift,
                                alt: current.alt,
                                enabled: value,
                              ),
                            );
                          } finally {
                            if (mounted) setState(() => saving = false);
                          }
                        },
                ),
                trailing: OutlinedButton(
                  onPressed: saving ? null : () => record(action),
                  child: const Text('录制'),
                ),
              ),
            if (shortcutSettings.apple)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '其他终端内快捷键（搜索、粘贴、标签数字）保持固定。',
                  style: TextStyle(fontSize: 11),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Windows 默认使用 Ctrl+Shift；其他终端内快捷键保持固定。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            const SizedBox(height: 10),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text(
                'GNU Readline 快捷键速查',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'shell 自带的行编辑能力，不占用上方可录制快捷键。',
                style: TextStyle(fontSize: 11),
              ),
              children: [
                for (final (keys, action) in const [
                  ('Ctrl+A / Ctrl+E', '行首 / 行尾'),
                  ('Ctrl+B / Ctrl+F', '左移 / 右移一个字符'),
                  ('Alt+B / Alt+F', '左移 / 右移一个单词'),
                  ('Ctrl+U / Ctrl+K', '删除到行首 / 行尾'),
                  ('Ctrl+W', '删除前一个单词'),
                  ('Ctrl+Y', '粘贴最近删除内容'),
                  ('Ctrl+R', '反向搜索历史'),
                  ('Ctrl+L', '清屏'),
                  ('Ctrl+C / Ctrl+D', '中断 / 结束输入'),
                  ('Ctrl+P / Ctrl+N', '上一条 / 下一条历史'),
                ])
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(keys),
                    trailing: Text(
                      action,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: saving ? null : reset,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('恢复默认'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _ShortcutRecorder extends StatefulWidget {
  final ShortcutAction action;
  const _ShortcutRecorder({required this.action});

  @override
  State<_ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<_ShortcutRecorder> {
  final focus = FocusNode();
  String hint = '请按下新的快捷键组合';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => focus.requestFocus());
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    final modifiers = {
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.altRight,
    };
    if (modifiers.contains(key)) {
      setState(() => hint = '继续按下一个字母或符号键');
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed) {
      setState(() => hint = '请至少使用一个修饰键');
      return KeyEventResult.handled;
    }
    Navigator.pop(
      context,
      ShortcutKey(
        keyId: key.keyId,
        meta: keyboard.isMetaPressed,
        control: keyboard.isControlPressed,
        shift: keyboard.isShiftPressed,
        alt: keyboard.isAltPressed,
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('录制：${widget.action.label}'),
    content: Focus(
      focusNode: focus,
      onKeyEvent: _onKey,
      child: const SizedBox(
        width: 360,
        height: 80,
        child: Center(child: Text('按下新的快捷键组合\nEsc 取消')),
      ),
    ),
  );
}
