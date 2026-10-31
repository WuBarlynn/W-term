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
  late final rules = TextEditingController(
    text: keywordHighlights.hostRules
        .map((rule) => '${rule.tags.join(',')}=${rule.pattern}')
        .join('\n'),
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
    rules.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final nextRules = <KeywordHighlightRule>[];
    for (final raw in rules.text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final separator = line.indexOf('=');
      final tagText = separator < 0 ? '' : line.substring(0, separator);
      final pattern = separator < 0 ? line : line.substring(separator + 1);
      if (pattern.trim().isEmpty) {
        setState(() => error = '正则规则不能为空');
        return;
      }
      try {
        RegExp(pattern);
      } catch (_) {
        setState(() => error = '正则无效：$pattern');
        return;
      }
      nextRules.add(
        KeywordHighlightRule(
          tagText
              .split(RegExp(r'[,，]'))
              .map((tag) => tag.trim())
              .where((tag) => tag.isNotEmpty)
              .toList(),
          pattern.trim(),
        ),
      );
      if (nextRules.length >= 20) break;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await keywordHighlights.save(
        nextEnabled: enabled,
        nextKeywords: text.text.split(RegExp(r'[\n,，;；]')),
        nextHostRules: nextRules,
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
            TextField(
              controller: rules,
              enabled: !saving,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '主机规则（可选）',
                hintText: 'web,prod=ERROR|CRITICAL\n=timeout',
                helperText: '每行“标签,标签=正则”；标签留空表示所有主机',
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
