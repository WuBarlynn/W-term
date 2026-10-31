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
  late bool windowsHardwareInput = pluginSettings.windowsHardwareInput;
  late bool linkUnderline = pluginSettings.linkUnderline;
  late bool dragUpload = pluginSettings.dragUpload;
  late int maxUploadSizeMb = pluginSettings.maxUploadSizeMb;
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
        windowsHardwareInputNext: windowsHardwareInput,
        linkUnderlineNext: linkUnderline,
        dragUploadNext: dragUpload,
        maxUploadSizeMbNext: maxUploadSizeMb,
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
    scrollable: true,
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
          SwitchListTile(
            value: dragUpload,
            onChanged: saving
                ? null
                : (value) => setState(() => dragUpload = value),
            title: const Text('拖拽上传'),
            subtitle: const Text('允许把本地文件/文件夹拖入文件面板上传'),
          ),
          DropdownButtonFormField<int>(
            initialValue: maxUploadSizeMb,
            decoration: const InputDecoration(labelText: '单文件上传大小上限'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('不限制')),
              DropdownMenuItem(value: 50, child: Text('50 MB')),
              DropdownMenuItem(value: 100, child: Text('100 MB')),
              DropdownMenuItem(value: 500, child: Text('500 MB')),
              DropdownMenuItem(value: 1024, child: Text('1 GB')),
              DropdownMenuItem(value: 2048, child: Text('2 GB')),
            ],
            onChanged: saving
                ? null
                : (value) => setState(() => maxUploadSizeMb = value ?? 0),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: linkUnderline,
            onChanged: saving
                ? null
                : (value) => setState(() => linkUnderline = value),
            title: const Text('终端链接自动下划线'),
            subtitle: const Text('识别 http/https 链接并绘制下划线；点击打开逻辑不变'),
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
          if (defaultTargetPlatform == TargetPlatform.windows)
            SwitchListTile(
              value: windowsHardwareInput,
              onChanged: saving
                  ? null
                  : (value) => setState(() => windowsHardwareInput = value),
              title: const Text('Windows 硬件键盘输入'),
              subtitle: const Text(
                '输入法异常或无法输入时的兼容模式：绕过 Flutter 文本输入，只接收硬件键盘；'
                '中文输入法组字可能不可用',
              ),
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
