import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/font_catalog.dart';
import '../app/imported_fonts.dart';
import '../app/terminal_appearance.dart';
import '../app/errors.dart';
import 'font_market_dialog.dart';

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
  late String skin = widget.store.skin;
  late bool copyOnSelect = widget.store.copyOnSelect;
  late Map<String, int> customColors = widget.store.customColors.isEmpty
      ? TerminalAppearance.defaultCustomColors(widget.store.palette)
      : Map.of(widget.store.customColors);
  late final uiFont = TextEditingController(text: widget.store.uiFont);
  late final terminalFont = TextEditingController(
    text: widget.store.terminalFont,
  );
  late final cjkFont = TextEditingController(text: widget.store.cjkFont);
  List<String> fontFamilies = curatedFontFamilies();
  bool importingFont = false;

  List<String> get _fontChoices =>
      {...fontFamilies, ...importedFonts.names}.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  @override
  void initState() {
    super.initState();
    unawaited(
      availableFontFamilies().then((families) {
        if (mounted) setState(() => fontFamilies = families);
      }),
    );
  }

  @override
  void dispose() {
    uiFont.dispose();
    terminalFont.dispose();
    cjkFont.dispose();
    super.dispose();
  }

  Future<void> _openFontMarket() async {
    await showDialog<void>(
      context: context,
      builder: (_) => FontMarketDialog(
        installed: importedFonts.names.toSet(),
        install: (entry) =>
            importedFonts.importUrl(Uri.parse(entry.url), entry.name),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> editCustomTheme() async {
    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (_) => _ThemeEditorDialog(colors: customColors),
    );
    if (result != null && mounted) {
      setState(() {
        customColors = result;
        palette = 'custom';
      });
    }
  }

  bool busy = false;
  String? error;

  Future<String?> _askFontName(String initial) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('字体名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(
            labelText: '显示名称',
            hintText: '例如 JetBrains Mono',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return null;
    final error = validateImportedFontName(name);
    if (error != null) {
      if (mounted) setState(() => this.error = error);
      return null;
    }
    return name.trim();
  }

  Future<void> _importFontFile() async {
    XFile? file;
    try {
      file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: '字体', extensions: ['ttf', 'otf', 'ttc']),
        ],
      );
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
      return;
    }
    if (file == null || !mounted) return;
    final base = file.name.contains('.')
        ? file.name.substring(0, file.name.lastIndexOf('.'))
        : file.name;
    final name = await _askFontName(base);
    if (name == null || !mounted) return;
    setState(() {
      importingFont = true;
      error = null;
    });
    try {
      await importedFonts.importFile(File(file.path), name);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => importingFont = false);
    }
  }

  Future<void> _importFontUrl() async {
    final url = TextEditingController();
    final family = TextEditingController();
    var dialogError = '';
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('从 URL 安装字体'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: url,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '字体文件 URL',
                    hintText: 'https://example.com/font.ttf',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: family,
                  maxLength: 64,
                  decoration: const InputDecoration(labelText: '字体显示名称'),
                ),
                if (dialogError.isNotEmpty)
                  Text(
                    dialogError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Text(
                  '仅支持 http/https 的 TTF/OTF/TTC，最大 32 MB。',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final uri = Uri.tryParse(url.text.trim());
                if (uri == null ||
                    (uri.scheme != 'http' && uri.scheme != 'https')) {
                  update(() => dialogError = '请输入 http/https 地址');
                  return;
                }
                final nameError = validateImportedFontName(family.text);
                if (nameError != null) {
                  update(() => dialogError = nameError);
                  return;
                }
                Navigator.pop(context, [url.text.trim(), family.text.trim()]);
              },
              child: const Text('开始下载'),
            ),
          ],
        ),
      ),
    );
    url.dispose();
    family.dispose();
    if (result == null || !mounted) return;
    setState(() {
      importingFont = true;
      error = null;
    });
    try {
      await importedFonts.importUrl(Uri.parse(result[0]), result[1]);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => importingFont = false);
    }
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await widget.store.save(
        palette,
        size,
        nextUiTheme: uiTheme,
        nextUiFont: uiFont.text.trim(),
        nextTerminalFont: terminalFont.text.trim(),
        nextCjkFont: cjkFont.text.trim(),
        nextSkin: skin,
        nextCustomColors: customColors,
        nextCopyOnSelect: copyOnSelect,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = palette == 'custom'
        ? TerminalAppearance.customTheme(customColors)
        : TerminalAppearance.themeFor(palette);
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
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '内置皮肤',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('无'),
                    selected: skin == 'none',
                    onSelected: busy
                        ? null
                        : (_) => setState(() => skin = 'none'),
                  ),
                  for (final entry in builtInSkins.entries)
                    ChoiceChip(
                      label: Text(entry.value.name),
                      selected: skin == entry.key,
                      onSelected: busy
                          ? null
                          : (_) => setState(() {
                              skin = entry.key;
                              palette = entry.value.palette;
                              uiTheme = entry.value.dark ? 'dark' : 'light';
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: busy ? null : editCustomTheme,
                  icon: const Icon(Icons.tune, size: 16),
                  label: Text(palette == 'custom' ? '编辑自定义配色' : '自定义终端主题'),
                ),
              ),
              const SizedBox(height: 8),
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
              const SizedBox(height: 12),
              _FontField(
                controller: uiFont,
                enabled: !busy,
                label: '界面字体',
                hint: '留空使用 ${platformDefaultUiFont()}',
                fonts: _fontChoices,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 10),
              _FontField(
                controller: terminalFont,
                enabled: !busy,
                label: '终端字体',
                hint: '留空使用 ${platformDefaultTerminalFont()}',
                fonts: _fontChoices,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 10),
              _FontField(
                controller: cjkFont,
                enabled: !busy,
                label: 'CJK 回退字体（可选）',
                hint: 'Noto Sans SC / Microsoft YaHei',
                fonts: _fontChoices,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 6),
              Text(
                '已内置 JetBrains Mono、Noto Sans SC；'
                '检测到 ${_fontChoices.length} 个可用字体族，点击右侧按钮选择。',
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy || importingFont ? null : _importFontFile,
                    icon: const Icon(Icons.font_download_outlined, size: 18),
                    label: const Text('导入字体文件'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || importingFont ? null : _importFontUrl,
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('从 URL 安装'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || importingFont ? null : _openFontMarket,
                    icon: const Icon(Icons.storefront_outlined, size: 18),
                    label: const Text('在线字体'),
                  ),
                  if (importingFont)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              if (importedFonts.entries.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final font in importedFonts.entries)
                      InputChip(
                        label: Text(font.name),
                        onDeleted: busy || importingFont
                            ? null
                            : () async {
                                await importedFonts.remove(font);
                                if (mounted) setState(() {});
                              },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 4),
              const Text(
                '导入字体仅复制到本机应用数据；请确认拥有该字体的使用授权。',
                style: TextStyle(fontSize: 11),
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('选中即复制'),
                subtitle: const Text('在终端中划选文字后自动写入剪贴板'),
                value: copyOnSelect,
                onChanged: busy
                    ? null
                    : (value) => setState(() => copyOnSelect = value),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                color: theme.background,
                child: Text(
                  'user@server ~ %\n连接成功 · Hello, terminal!\n'
                  '中文渲染 abcdef 0123456789',
                  style: TextStyle(
                    color: theme.foreground,
                    fontSize: size.toDouble(),
                    fontFamily: terminalFont.text.trim().isEmpty
                        ? platformDefaultTerminalFont()
                        : terminalFont.text.trim(),
                    fontFamilyFallback: [
                      if (cjkFont.text.trim().isNotEmpty) cjkFont.text.trim(),
                      if (Theme.of(context).platform == TargetPlatform.windows)
                        'Microsoft YaHei UI'
                      else
                        'PingFang SC',
                      'Noto Sans SC',
                      'monospace',
                    ],
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

String _argbHex(int value) =>
    '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';

int? _parseArgbHex(String value) {
  final text = value.replaceFirst('#', '').trim();
  if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(text)) {
    return null;
  }
  final parsed = int.parse(text, radix: 16);
  return text.length == 6 ? 0xff000000 | parsed : parsed;
}

class _ThemeEditorDialog extends StatefulWidget {
  final Map<String, int> colors;
  const _ThemeEditorDialog({required this.colors});
  @override
  State<_ThemeEditorDialog> createState() => _ThemeEditorDialogState();
}

class _ThemeEditorDialogState extends State<_ThemeEditorDialog> {
  late final Map<String, int> _colors = {
    ...TerminalAppearance.defaultCustomColors('dark'),
    ...widget.colors,
  };
  late final Map<String, TextEditingController> _controllers = {
    for (final key in TerminalAppearance.customColorLabels.keys)
      key: TextEditingController(text: _argbHex(_colors[key]!)),
  };
  String? error;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _update(String key, int value) {
    setState(() {
      _colors[key] = value;
      _controllers[key]!.text = _argbHex(value);
    });
  }

  Future<void> _pick(String key) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _ColorPickerDialog(initial: Color(_colors[key]!)),
    );
    if (picked != null && mounted) _update(key, picked.toARGB32());
  }

  void _loadPalette(String palette) {
    final seed = TerminalAppearance.defaultCustomColors(palette);
    setState(() {
      _colors
        ..clear()
        ..addAll(seed);
      for (final entry in _controllers.entries) {
        entry.value.text = _argbHex(seed[entry.key]!);
      }
    });
  }

  void _save() {
    final next = <String, int>{};
    for (final entry in _controllers.entries) {
      final value = _parseArgbHex(entry.value.text);
      if (value == null) {
        setState(
          () => error =
              '「${TerminalAppearance.customColorLabels[entry.key]}」颜色格式无效，应为 #RRGGBB 或 #AARRGGBB',
        );
        return;
      }
      next[entry.key] = value;
    }
    Navigator.pop(context, next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = TerminalAppearance.customTheme(_colors);
    return AlertDialog(
      title: const Text('自定义终端主题'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '调整 16 色与光标、选区和背景，保存后立即应用到所有终端。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '载入内置配色作为起点',
                  onSelected: _loadPalette,
                  itemBuilder: (_) => [
                    for (final entry in TerminalAppearance.names.entries)
                      if (entry.key != 'custom')
                        PopupMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text('载入内置配色', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final key in TerminalAppearance.customColorLabels.keys)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 64,
                            child: Text(
                              TerminalAppearance.customColorLabels[key]!,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => _pick(key),
                            child: Container(
                              width: 46,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Color(_colors[key]!),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 36,
                              child: TextField(
                                controller: _controllers[key],
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  fontFamilyFallback: monoFontFallback,
                                ),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                ),
                                onChanged: (value) {
                                  final parsed = _parseArgbHex(value);
                                  if (parsed != null) {
                                    setState(() {
                                      _colors[key] = parsed;
                                      error = null;
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                r'user@server ~ % ls'
                '\n'
                r'logs  notes.txt  project',
                style: TextStyle(
                  color: theme.foreground,
                  fontFamily: 'monospace',
                  fontFamilyFallback: monoFontFallback,
                  fontSize: 12,
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('使用此配色')),
      ],
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  final Color initial;
  const _ColorPickerDialog({required this.initial});
  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _color = HSVColor.fromColor(widget.initial);

  @override
  Widget build(BuildContext context) {
    final color = _color.toColor();
    return AlertDialog(
      title: const Text('选择颜色'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 56,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              alignment: Alignment.center,
              child: Text(
                _argbHex(color.toARGB32()),
                style: TextStyle(
                  color:
                      ThemeData.estimateBrightnessForColor(color) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                  fontFamily: 'monospace',
                  fontFamilyFallback: monoFontFallback,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('色相 ${_color.hue.round()}°'),
            Slider(
              max: 360,
              value: _color.hue,
              onChanged: (v) => setState(() => _color = _color.withHue(v)),
            ),
            Text('饱和度 ${(_color.saturation * 100).round()}%'),
            Slider(
              value: _color.saturation,
              onChanged: (v) =>
                  setState(() => _color = _color.withSaturation(v)),
            ),
            Text('明度 ${(_color.value * 100).round()}%'),
            Slider(
              value: _color.value,
              onChanged: (v) => setState(() => _color = _color.withValue(v)),
            ),
            Text('不透明度 ${(_color.alpha * 100).round()}%'),
            Slider(
              value: _color.alpha,
              onChanged: (v) => setState(() => _color = _color.withAlpha(v)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _color.toColor()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _FontField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final String label;
  final String hint;
  final List<String> fonts;
  final VoidCallback? onChanged;
  const _FontField({
    required this.controller,
    required this.enabled,
    required this.label,
    required this.hint,
    required this.fonts,
    this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (_) =>
          _FontPickerDialog(fonts: fonts, selected: controller.text.trim()),
    );
    if (choice == null) return;
    controller.text = choice;
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    onChanged: (_) => onChanged?.call(),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: IconButton(
        tooltip: '选择已安装或内置字体',
        onPressed: enabled ? () => _pick(context) : null,
        icon: const Icon(Icons.font_download_outlined, size: 20),
      ),
    ),
  );
}

class _FontPickerDialog extends StatefulWidget {
  final List<String> fonts;
  final String selected;
  const _FontPickerDialog({required this.fonts, required this.selected});
  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  late final TextEditingController search = TextEditingController();
  late String query = '';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = query.toLowerCase();
    final filtered = widget.fonts
        .where((font) => value.isEmpty || font.toLowerCase().contains(value))
        .toList();
    return AlertDialog(
      title: const Text('选择字体'),
      content: SizedBox(
        width: 460,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: search,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索字体名称',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
              onChanged: (text) => setState(() => query = text),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    final selected = widget.selected.isEmpty;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      leading: const Icon(Icons.settings_backup_restore),
                      title: const Text('系统默认（留空）'),
                      onTap: () => Navigator.pop(context, ''),
                    );
                  }
                  final font = filtered[index - 1];
                  final selected = font == widget.selected;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    leading: Text(
                      'Aa',
                      style: TextStyle(fontFamily: font, fontSize: 16),
                    ),
                    title: Text(
                      font,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: font,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: selected
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () => Navigator.pop(context, font),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
