import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/plugins.dart';

class WorkspaceSettingsDialog extends StatefulWidget {
  const WorkspaceSettingsDialog({super.key});

  @override
  State<WorkspaceSettingsDialog> createState() =>
      _WorkspaceSettingsDialogState();
}

class _WorkspaceSettingsDialogState extends State<WorkspaceSettingsDialog> {
  late bool compactTabs = pluginSettings.compactTabs;
  late bool showFavoritesBar = pluginSettings.showFavoritesBar;
  late bool clickTabLocates = pluginSettings.clickTabLocates;
  late bool restoreLayout = pluginSettings.restoreLayout;
  late bool showStatusBar = pluginSettings.showStatusBar;
  late bool rightClickPaste = pluginSettings.rightClickPaste;
  late bool showComposeBar = pluginSettings.showComposeBar;
  bool saving = false;
  String error = '';

  Future<void> save() async {
    setState(() {
      saving = true;
      error = '';
    });
    try {
      await pluginSettings.save(
        json: pluginSettings.jsonFormatter,
        ip: pluginSettings.ipLookup,
        preview: pluginSettings.filePreview,
        completion: pluginSettings.commandCompletion,
        notifications: pluginSettings.taskNotifications,
        compactTabsNext: compactTabs,
        showFavoritesBarNext: showFavoritesBar,
        clickTabLocatesNext: clickTabLocates,
        restoreLayoutNext: restoreLayout,
        showStatusBarNext: showStatusBar,
        rightClickPasteNext: rightClickPaste,
        showComposeBarNext: showComposeBar,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('工作区偏好'),
    content: SizedBox(
      width: 480,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: compactTabs,
            onChanged: saving
                ? null
                : (value) => setState(() => compactTabs = value),
            title: const Text('紧凑标签栏'),
            subtitle: const Text('降低标签高度，为终端留出更多空间。'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: showFavoritesBar,
            onChanged: saving
                ? null
                : (value) => setState(() => showFavoritesBar = value),
            title: const Text('显示收藏栏'),
            subtitle: const Text('在终端顶部显示收藏主机与数字快捷键。'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: clickTabLocates,
            onChanged: saving
                ? null
                : (value) => setState(() => clickTabLocates = value),
            title: const Text('点击标签定位连接'),
            subtitle: const Text('切换标签时在主机列表中选择对应主机。'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: restoreLayout,
            onChanged: saving
                ? null
                : (value) => setState(() => restoreLayout = value),
            title: const Text('启动恢复上次布局'),
            subtitle: const Text('下次启动以未连接窗格恢复标签、分屏与目录。'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: showStatusBar,
            onChanged: saving
                ? null
                : (value) => setState(() => showStatusBar = value),
            title: const Text('显示实时状态栏'),
            subtitle: const Text('每 10 秒采样 SSH 延迟、CPU 与内存，依赖远端 /proc。'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: rightClickPaste,
            onChanged: saving
                ? null
                : (value) => setState(() => rightClickPaste = value),
            title: const Text('右键直接粘贴'),
            subtitle: const Text('默认关闭右键菜单；开启后右键立即粘贴剪贴板。'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: showComposeBar,
            onChanged: saving
                ? null
                : (value) => setState(() => showComposeBar = value),
            title: const Text('显示底部撰写栏'),
            subtitle: const Text('在终端底部编辑多行命令，发送到当前输入目标。'),
          ),
          if (error.isNotEmpty)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        child: saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('保存'),
      ),
    ],
  );
}
