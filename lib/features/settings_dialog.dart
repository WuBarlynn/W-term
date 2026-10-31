import 'package:flutter/material.dart';

class SettingsEntry {
  final String action;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool closeOnAction;
  const SettingsEntry({
    required this.action,
    required this.title,
    this.subtitle = '',
    required this.icon,
    this.closeOnAction = false,
  });
}

class SettingsSection {
  final String title;
  final IconData icon;
  final List<SettingsEntry> entries;
  const SettingsSection({
    required this.title,
    required this.icon,
    required this.entries,
  });
}

class AppSettingsDialog extends StatefulWidget {
  final List<SettingsSection> sections;
  final bool autoSyncEnabled;
  final bool showAutoSync;
  final Future<bool> Function(bool enabled) onAutoSyncChanged;
  final Future<void> Function(String action) onAction;
  final String version;
  const AppSettingsDialog({
    super.key,
    required this.sections,
    required this.autoSyncEnabled,
    required this.showAutoSync,
    required this.onAutoSyncChanged,
    required this.onAction,
    required this.version,
  });

  @override
  State<AppSettingsDialog> createState() => _AppSettingsDialogState();
}

class _AppSettingsDialogState extends State<AppSettingsDialog> {
  int selected = 0;
  bool autoSync = false;
  bool busy = false;

  List<SettingsSection> get sections {
    final result = <SettingsSection>[...widget.sections];
    if (widget.showAutoSync) {
      final sync = result.indexWhere((section) => section.title == '同步');
      if (sync >= 0) {
        result[sync] = SettingsSection(
          title: result[sync].title,
          icon: result[sync].icon,
          entries: [
            ...result[sync].entries,
            SettingsEntry(
              action: 'auto-sync',
              title: '自动同步',
              subtitle: autoSync ? '每 15 分钟同步一次' : '已关闭',
              icon: Icons.sync,
            ),
          ],
        );
      }
    }
    result.add(
      SettingsSection(
        title: '关于',
        icon: Icons.info_outline,
        entries: [
          SettingsEntry(
            action: 'about',
            title: 'W Term',
            subtitle: widget.version,
            icon: Icons.terminal,
          ),
        ],
      ),
    );
    return result;
  }

  @override
  void initState() {
    super.initState();
    autoSync = widget.autoSyncEnabled;
  }

  Future<void> run(SettingsEntry entry) async {
    if (busy) return;
    if (entry.action == 'auto-sync') {
      setState(() => busy = true);
      try {
        final changed = await widget.onAutoSyncChanged(!autoSync);
        if (mounted && changed) setState(() => autoSync = !autoSync);
      } finally {
        if (mounted) setState(() => busy = false);
      }
      return;
    }
    if (entry.action == 'about') return;
    if (entry.closeOnAction && mounted) Navigator.of(context).pop();
    await widget.onAction(entry.action);
  }

  @override
  Widget build(BuildContext context) {
    final active = sections[selected.clamp(0, sections.length - 1)];
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('设置'),
          actions: [
            IconButton(
              tooltip: '关闭设置',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            final navigation = _SettingsNavigation(
              sections: sections,
              selected: selected,
              horizontal: !wide,
              onSelected: (index) => setState(() => selected = index),
            );
            final list = _SettingsList(
              section: active,
              autoSync: autoSync,
              busy: busy,
              onTap: run,
            );
            if (wide) {
              return Row(
                children: [
                  SizedBox(width: 220, child: navigation),
                  const VerticalDivider(width: 1),
                  Expanded(child: list),
                ],
              );
            }
            return Column(
              children: [
                SizedBox(height: 52, child: navigation),
                const Divider(height: 1),
                Expanded(child: list),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SettingsNavigation extends StatelessWidget {
  final List<SettingsSection> sections;
  final int selected;
  final bool horizontal;
  final ValueChanged<int> onSelected;
  const _SettingsNavigation({
    required this.sections,
    required this.selected,
    required this.horizontal,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (horizontal) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: sections.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) => Center(
          child: ChoiceChip(
            key: ValueKey('settings-nav-${sections[index].title}'),
            selected: selected == index,
            avatar: Icon(sections[index].icon, size: 16),
            label: Text(sections[index].title),
            onSelected: (_) => onSelected(index),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (var index = 0; index < sections.length; index++)
          ListTile(
            key: ValueKey('settings-nav-${sections[index].title}'),
            selected: selected == index,
            leading: Icon(sections[index].icon),
            title: Text(sections[index].title),
            onTap: () => onSelected(index),
          ),
      ],
    );
  }
}

class _SettingsList extends StatelessWidget {
  final SettingsSection section;
  final bool autoSync;
  final bool busy;
  final Future<void> Function(SettingsEntry entry) onTap;
  const _SettingsList({
    required this.section,
    required this.autoSync,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      children: [
        Text(section.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (var index = 0; index < section.entries.length; index++) ...[
                if (index > 0) const Divider(height: 1),
                ListTile(
                  key: ValueKey('settings-entry-${section.entries[index].action}'),
                  leading: Icon(section.entries[index].icon),
                  title: Text(section.entries[index].title),
                  subtitle: section.entries[index].subtitle.isEmpty
                      ? null
                      : Text(section.entries[index].subtitle),
                  trailing: section.entries[index].action == 'auto-sync'
                      ? Switch(
                          value: autoSync,
                          onChanged: busy
                              ? null
                              : (_) => onTap(section.entries[index]),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: busy ? null : () => onTap(section.entries[index]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
