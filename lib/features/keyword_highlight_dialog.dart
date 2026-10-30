import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/keyword_highlights.dart';

class KeywordHighlightDialog extends StatefulWidget {
  const KeywordHighlightDialog({super.key});
  @override
  State<KeywordHighlightDialog> createState() => _KeywordHighlightDialogState();
}

class _KeywordHighlightDialogState extends State<KeywordHighlightDialog> {
  late bool enabled = keywordHighlights.enabled;
  late final text = TextEditingController(
    text: keywordHighlights.keywords.join('\n'),
  );
  late int color = keywordHighlights.colorArgb;
  bool saving = false;
  String? error;

  static const colors = <(String, int)>[
    ('黄', 0xFFFFD166),
    ('橙', 0xFFFF9F43),
    ('红', 0xFFFF6B6B),
    ('青', 0xFF4FD1C5),
    ('紫', 0xFFB794F4),
  ];

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await keywordHighlights.save(
        nextEnabled: enabled,
        nextKeywords: text.text.split(RegExp(r'[\n,，;；]')),
        nextColorArgb: color,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('关键字高亮'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用关键字高亮'),
              subtitle: const Text('在当前终端缓冲区中标记匹配文本（最多 20 个关键字）'),
              value: enabled,
              onChanged: saving
                  ? null
                  : (value) => setState(() => enabled = value),
            ),
            TextField(
              controller: text,
              enabled: !saving,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '关键字',
                hintText: 'ERROR\nWARNING\n失败',
                helperText: '换行、逗号或分号分隔；不区分大小写',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final (label, value) in colors)
                  ChoiceChip(
                    label: Text(label),
                    selected: color == value,
                    onSelected: saving
                        ? null
                        : (_) => setState(() => color = value),
                    avatar: CircleAvatar(backgroundColor: Color(value)),
                  ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
