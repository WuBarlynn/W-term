import 'package:flutter/material.dart';

class FontMarketEntry {
  final String name, description, url;
  const FontMarketEntry({
    required this.name,
    required this.description,
    required this.url,
  });
}

/// Open-license fonts fetched from their upstream public repositories.
const fontMarketCatalog = <FontMarketEntry>[
  FontMarketEntry(
    name: 'Fira Code',
    description: '带连字的等宽编程字体',
    url:
        'https://raw.githubusercontent.com/google/fonts/main/ofl/firacode/FiraCode%5Bwght%5D.ttf',
  ),
  FontMarketEntry(
    name: 'Source Code Pro',
    description: 'Adobe 开源等宽字体',
    url:
        'https://raw.githubusercontent.com/google/fonts/main/ofl/sourcecodepro/SourceCodePro%5Bwght%5D.ttf',
  ),
  FontMarketEntry(
    name: 'IBM Plex Mono',
    description: 'IBM 企业风格等宽字体',
    url:
        'https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Regular.ttf',
  ),
  FontMarketEntry(
    name: 'Space Mono',
    description: '几何感较强的等宽字体',
    url:
        'https://raw.githubusercontent.com/google/fonts/main/ofl/spacemono/SpaceMono-Regular.ttf',
  ),
  FontMarketEntry(
    name: 'Noto Sans Mono',
    description: '覆盖广泛的等宽字体',
    url:
        'https://raw.githubusercontent.com/google/fonts/main/ofl/notosansmono/NotoSansMono%5Bwdth,wght%5D.ttf',
  ),
  FontMarketEntry(
    name: 'Roboto Mono',
    description: 'Google 界面风格等宽字体',
    url:
        'https://raw.githubusercontent.com/google/fonts/main/ofl/robotomono/RobotoMono%5Bwght%5D.ttf',
  ),
];

class FontMarketDialog extends StatefulWidget {
  final Set<String> installed;
  final Future<void> Function(FontMarketEntry entry) install;
  const FontMarketDialog({
    super.key,
    required this.installed,
    required this.install,
  });

  @override
  State<FontMarketDialog> createState() => _FontMarketDialogState();
}

class _FontMarketDialogState extends State<FontMarketDialog> {
  late final Set<String> installed = {...widget.installed};
  String installing = '';
  String error = '';

  Future<void> run(FontMarketEntry entry) async {
    if (installing.isNotEmpty) return;
    setState(() {
      installing = entry.name;
      error = '';
    });
    try {
      await widget.install(entry);
      if (mounted) setState(() => installed.add(entry.name));
    } catch (e) {
      if (mounted) setState(() => error = '安装失败：$e');
    } finally {
      if (mounted) setState(() => installing = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('在线字体'),
      content: SizedBox(
        width: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('从 GitHub 开源字体仓库下载，遵循 SIL Open Font License 1.1。'),
            if (error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 8),
            for (final entry in fontMarketCatalog)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.name),
                subtitle: Text(entry.description),
                trailing: installed.contains(entry.name)
                    ? const Chip(label: Text('已安装'))
                    : FilledButton.tonal(
                        key: ValueKey('font-install-${entry.name}'),
                        onPressed: installing.isEmpty ? () => run(entry) : null,
                        child: installing == entry.name
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('安装'),
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
}
