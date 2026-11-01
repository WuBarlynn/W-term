import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../app/errors.dart';
import '../app/terminal_appearance.dart';

class SkinGalleryResult {
  final String skin;
  final List<CustomSkin> customSkins;
  const SkinGalleryResult(this.skin, this.customSkins);
}

class SkinGalleryDialog extends StatefulWidget {
  final TerminalAppearance store;
  const SkinGalleryDialog({super.key, required this.store});
  @override
  State<SkinGalleryDialog> createState() => _SkinGalleryDialogState();
}

class _SkinGalleryDialogState extends State<SkinGalleryDialog> {
  late List<CustomSkin> customSkins = [...widget.store.customSkins];
  late String selected = widget.store.skin;

  Future<void> edit([CustomSkin? existing]) async {
    final result = await showDialog<CustomSkin>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CustomSkinEditorDialog(
        existing: existing,
        customColors: widget.store.customColors,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      final index = customSkins.indexWhere((item) => item.id == result.id);
      if (index >= 0) {
        customSkins[index] = result;
      } else {
        customSkins.add(result);
      }
      selected = 'custom:${result.id}';
    });
  }

  void delete(CustomSkin skin) {
    setState(() {
      customSkins.removeWhere((item) => item.id == skin.id);
      if (selected == 'custom:${skin.id}') selected = 'none';
    });
  }

  @override
  Widget build(BuildContext context) {
    final builtIns = builtInSkins.entries.toList();
    return AlertDialog(
      title: const Text('皮肤'),
      content: SizedBox(
        width: 620,
        height: 460,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.25,
          ),
          itemCount: builtIns.length + customSkins.length + 1,
          itemBuilder: (context, index) {
            if (index < builtIns.length) {
              final entry = builtIns[index];
              return _SkinCard(
                name: entry.value.name,
                dark: entry.value.dark,
                top: entry.value.top,
                bottom: entry.value.bottom,
                selected: selected == entry.key,
                onTap: () => Navigator.pop(
                  context,
                  SkinGalleryResult(entry.key, customSkins),
                ),
              );
            }
            final customIndex = index - builtIns.length;
            if (customIndex < customSkins.length) {
              final skin = customSkins[customIndex];
              return _SkinCard(
                name: skin.name,
                dark: skin.dark,
                top: skin.base,
                bottom: skin.base,
                image: skin.background,
                selected: selected == 'custom:${skin.id}',
                onTap: () => Navigator.pop(
                  context,
                  SkinGalleryResult('custom:${skin.id}', customSkins),
                ),
                onEdit: () => edit(skin),
                onDelete: () => delete(skin),
              );
            }
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => edit(),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_circle_outline, size: 28),
                    SizedBox(height: 8),
                    Text('新建皮肤'),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            SkinGalleryResult(selected, customSkins),
          ),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class _SkinCard extends StatelessWidget {
  final String name;
  final bool dark;
  final int top, bottom;
  final Uint8List? image;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _SkinCard({
    required this.name,
    required this.dark,
    required this.top,
    required this.bottom,
    this.image,
    required this.selected,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = dark ? Colors.white : const Color(0xff17201d);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image != null)
              Image.memory(image!, fit: BoxFit.cover)
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(top), Color(bottom)],
                  ),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  name,
                  style: TextStyle(color: foreground, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (onEdit != null)
              Positioned(
                top: 2,
                right: 2,
                child: PopupMenuButton<String>(
                  tooltip: '编辑皮肤',
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (value) =>
                      value == 'edit' ? onEdit?.call() : onDelete?.call(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CustomSkinEditorDialog extends StatefulWidget {
  final CustomSkin? existing;
  final Map<String, int> customColors;
  const CustomSkinEditorDialog({
    super.key,
    this.existing,
    this.customColors = const {},
  });
  @override
  State<CustomSkinEditorDialog> createState() =>
      _CustomSkinEditorDialogState();
}

class _CustomSkinEditorDialogState extends State<CustomSkinEditorDialog> {
  late final TextEditingController name = TextEditingController(
    text: widget.existing?.name ?? '我的皮肤',
  );
  late bool dark = widget.existing?.dark ?? true;
  late Color base = Color(widget.existing?.base ?? 0xff10231f);
  late Color seed = Color(widget.existing?.seed ?? 0xff36c9a8);
  late double overlay = widget.existing?.overlay ?? 0.20;
  late String palette = widget.existing?.palette ?? 'auto';
  Uint8List? background;
  String? error;

  @override
  void initState() {
    super.initState();
    background = widget.existing?.background;
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> chooseBackground() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '背景图片',
            extensions: ['png', 'jpg', 'jpeg', 'webp'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 30 * 1024 * 1024) {
        throw const FormatException('背景图片不能超过 30 MiB');
      }
      final compressed = _compress(bytes);
      setState(() {
        background = compressed;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  Uint8List _compress(Uint8List bytes) {
    var decoded = img.decodeImage(bytes);
    if (decoded == null) throw const FormatException('无法读取该图片');
    if (decoded.width > 1920) {
      decoded = img.copyResize(decoded, width: 1920);
    }
    var quality = 82;
    var encoded = Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
    while (encoded.length > CustomSkin.maxBackgroundBytes && quality > 40) {
      quality -= 10;
      encoded = Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
    }
    if (encoded.length > CustomSkin.maxBackgroundBytes) {
      decoded = img.copyResize(decoded, width: 1280);
      encoded = Uint8List.fromList(img.encodeJpg(decoded, quality: 55));
    }
    if (encoded.length > CustomSkin.maxBackgroundBytes) {
      throw const FormatException('背景图片压缩后仍超过 2 MiB，请选择更小的图片');
    }
    return encoded;
  }

  Future<void> pickColor(bool foreground) async {
    final color = await showDialog<Color>(
      context: context,
      builder: (_) => _SkinColorDialog(
        initial: foreground ? seed : base,
        title: foreground ? '主色' : '界面底色',
      ),
    );
    if (color == null || !mounted) return;
    setState(() {
      if (foreground) {
        seed = color;
      } else {
        base = color;
      }
    });
  }

  void save() {
    final trimmed = name.text.trim();
    if (trimmed.isEmpty || trimmed.length > 64) {
      setState(() => error = '请输入 1–64 个字符的皮肤名称');
      return;
    }
    Navigator.pop(
      context,
      CustomSkin(
        id: widget.existing?.id ??
            'custom-${DateTime.now().microsecondsSinceEpoch}',
        name: trimmed,
        palette: palette,
        dark: dark,
        seed: seed.toARGB32(),
        base: base.toARGB32(),
        overlay: overlay,
        background: background,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = CustomSkin(
      id: 'preview',
      name: name.text.trim().isEmpty ? '预览' : name.text.trim(),
      palette: palette,
      dark: dark,
      seed: seed.toARGB32(),
      base: base.toARGB32(),
      overlay: overlay,
      background: background,
    );
    return AlertDialog(
      title: Text(widget.existing == null ? '新建皮肤' : '编辑皮肤'),
      scrollable: true,
      content: SizedBox(
        width: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SkinPreview(skin: preview),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '皮肤名称'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: chooseBackground,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('选择背景图片'),
                ),
                if (background != null)
                  TextButton.icon(
                    onPressed: () => setState(() => background = null),
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('移除背景'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => pickColor(false),
                  icon: Icon(Icons.circle, color: base, size: 16),
                  label: const Text('界面底色'),
                ),
                OutlinedButton.icon(
                  onPressed: () => pickColor(true),
                  icon: Icon(Icons.circle, color: seed, size: 16),
                  label: const Text('主色'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('深色界面'),
              value: dark,
              onChanged: (value) => setState(() => dark = value),
            ),
            Text('背景色罩强度：${(overlay * 100).round()}%'),
            Slider(
              min: 0,
              max: 0.6,
              divisions: 12,
              value: overlay,
              label: '${(overlay * 100).round()}%',
              onChanged: (value) => setState(() => overlay = value),
            ),
            DropdownButtonFormField<String>(
              initialValue: palette,
              decoration: const InputDecoration(labelText: '终端主题'),
              items: [
                const DropdownMenuItem(value: 'auto', child: Text('自动玻璃')),
                for (final entry in TerminalAppearance.names.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
              ],
              onChanged: (value) => setState(() => palette = value ?? 'auto'),
            ),
            if (background != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '背景已压缩为 ${(background!.length / 1024).toStringAsFixed(0)} KiB',
                  style: const TextStyle(fontSize: 11),
                ),
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
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: save, child: const Text('保存皮肤')),
      ],
    );
  }
}

class _SkinPreview extends StatelessWidget {
  final CustomSkin skin;
  const _SkinPreview({required this.skin});
  @override
  Widget build(BuildContext context) {
    final foreground = skin.dark ? Colors.white : const Color(0xff17201d);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 140,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (skin.background != null)
              Image.memory(skin.background!, fit: BoxFit.cover)
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(skin.base),
                      Color(skin.seed).withValues(alpha: 0.8),
                    ],
                  ),
                ),
              ),
            ColoredBox(
              color: Color(skin.base).withValues(alpha: skin.overlay),
            ),
            Center(
              child: Container(
                width: 280,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Color(skin.base).withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  'user@server ~ %\n连接成功 · 皮肤预览',
                  style: TextStyle(
                    color: foreground,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkinColorDialog extends StatefulWidget {
  final Color initial;
  final String title;
  const _SkinColorDialog({required this.initial, required this.title});
  @override
  State<_SkinColorDialog> createState() => _SkinColorDialogState();
}

class _SkinColorDialogState extends State<_SkinColorDialog> {
  late Color value = widget.initial;
  late final TextEditingController hex = TextEditingController(
    text: '#${widget.initial.toARGB32().toRadixString(16).padLeft(8, '0')}',
  );
  String? error;

  static const presets = [
    Color(0xff10231f),
    Color(0xff071f1b),
    Color(0xff123b4a),
    Color(0xff1f2430),
    Color(0xff2e3440),
    Color(0xff282a36),
    Color(0xffffe3c8),
    Color(0xfffff0f4),
    Color(0xffedf2ef),
    Color(0xffe8f8ff),
    Color(0xff167768),
    Color(0xff36c9a8),
    Color(0xffb85c38),
    Color(0xff5b7cfa),
    Color(0xffc25b7c),
    Color(0xffb34dff),
  ];

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  void applyHex() {
    final text = hex.text.trim().replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(text)) {
      setState(() => error = '请输入 #RRGGBB 或 #AARRGGBB');
      return;
    }
    final parsed = int.parse(text, radix: 16);
    setState(() {
      value = Color(text.length == 6 ? 0xff000000 | parsed : parsed);
      error = null;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in presets)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setState(() {
                      value = color;
                      hex.text =
                          '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';
                    });
                  },
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: value == color
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white24,
                        width: value == color ? 2 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: hex,
            decoration: InputDecoration(
              labelText: '颜色值',
              errorText: error,
            ),
            onSubmitted: (_) => applyHex(),
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
          applyHex();
          if (error == null) Navigator.pop(context, value);
        },
        child: const Text('确定'),
      ),
    ],
  );
}
