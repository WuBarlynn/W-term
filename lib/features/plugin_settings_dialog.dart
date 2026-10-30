import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/plugins.dart';
import '../app/system_notifications.dart';

class PluginSettingsDialog extends StatefulWidget {
  const PluginSettingsDialog({super.key});
  @override
  State<PluginSettingsDialog> createState() => _PluginSettingsDialogState();
}

class _PluginSettingsDialogState extends State<PluginSettingsDialog> {
  late bool json = pluginSettings.jsonFormatter;
  late bool ip = pluginSettings.ipLookup;
  late bool preview = pluginSettings.filePreview;
  late bool completion = pluginSettings.commandCompletion;
  late bool notifications = pluginSettings.taskNotifications;
  late bool imeAutoEnglish = pluginSettings.imeAutoEnglish;
  bool saving = false;
  String? error;

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await pluginSettings.save(
        json: json,
        ip: ip,
        preview: preview,
        completion: completion,
        notifications: notifications,
        imeAutoEnglishNext: imeAutoEnglish,
      );
      if (notifications) unawaited(systemNotifications.setup());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('插件'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            value: json,
            onChanged: saving ? null : (value) => setState(() => json = value),
            title: const Text('JSON 格式化'),
            subtitle: const Text('选中 JSON 后从终端右键菜单格式化'),
          ),
          SwitchListTile(
            value: preview,
            onChanged: saving
                ? null
                : (value) => setState(() => preview = value),
            title: const Text('文件预览'),
            subtitle: const Text('选中远程路径后预览文本或图片'),
          ),
          SwitchListTile(
            value: ip,
            onChanged: saving ? null : (value) => setState(() => ip = value),
            title: const Text('IP 归属查询'),
            subtitle: const Text('选中 IPv4 后查询国家、城市与运营商（需要网络）'),
          ),
          SwitchListTile(
            value: completion,
            onChanged: saving
                ? null
                : (value) => setState(() => completion = value),
            title: const Text('命令补全'),
            subtitle: const Text('输入 git、docker、kubectl 等命令时在终端底部显示参数提示'),
          ),
          SwitchListTile(
            value: notifications,
            onChanged: saving
                ? null
                : (value) => setState(() => notifications = value),
            title: const Text('任务完成通知'),
            subtitle: const Text('长命令输出停止后提示完成；编辑器、分页器、远程会话等交互命令不通知'),
          ),
          if (defaultTargetPlatform == TargetPlatform.macOS)
            SwitchListTile(
              value: imeAutoEnglish,
              onChanged: saving
                  ? null
                  : (value) => setState(() => imeAutoEnglish = value),
              title: const Text('终端自动切英文输入'),
              subtitle: const Text('聚焦终端时切到 ASCII 键盘，离开时恢复原输入法'),
            ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '补全基于内置命令表，不会替代远端 shell 自身的 Tab 补全。',
              style: TextStyle(fontSize: 11),
            ),
          ),
          if (error != null)
            Align(
              alignment: Alignment.centerLeft,
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
      FilledButton(onPressed: saving ? null : save, child: const Text('保存')),
    ],
  );
}
