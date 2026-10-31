import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/onboarding.dart';
import '../app/plugins.dart';
import '../app/terminal_appearance.dart';

class OnboardingDialog extends StatefulWidget {
  final TerminalAppearance appearance;
  final PluginSettings plugins;
  final OnboardingStore store;
  final List<String> fontChoices;
  const OnboardingDialog({
    super.key,
    required this.appearance,
    required this.plugins,
    required this.store,
    required this.fontChoices,
  });

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  int step = 0;
  late String palette = widget.appearance.palette;
  late String uiTheme = widget.appearance.uiTheme;
  late String skin = widget.appearance.skin;
  late String terminalFont = widget.appearance.terminalFont;
  late int fontSize = widget.appearance.fontSize;
  late bool copyOnSelect = widget.appearance.copyOnSelect;
  late bool linkUnderline = widget.plugins.linkUnderline;
  late bool dragUpload = widget.plugins.dragUpload;
  late bool jsonFormatter = widget.plugins.jsonFormatter;
  late bool ipLookup = widget.plugins.ipLookup;
  late bool filePreview = widget.plugins.filePreview;
  late bool completion = widget.plugins.commandCompletion;
  late bool notifications = widget.plugins.taskNotifications;
  bool busy = false;
  String error = '';

  static const _titles = ['选择主题与皮肤', '选择终端字体', '常用偏好', '启用插件', 'GitHub 同步'];

  Future<void> finish() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.appearance.save(
        palette,
        fontSize,
        nextUiTheme: uiTheme,
        nextTerminalFont: terminalFont,
        nextSkin: skin,
        nextCopyOnSelect: copyOnSelect,
      );
      await widget.plugins.save(
        json: jsonFormatter,
        ip: ipLookup,
        preview: filePreview,
        completion: completion,
        notifications: notifications,
        linkUnderlineNext: linkUnderline,
        dragUploadNext: dragUpload,
      );
      await widget.store.complete();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> skip() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.store.complete();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _terminalPreview() {
    final theme = TerminalAppearance.themeFor(palette);
    final double size = fontSize.toDouble().clamp(10, 20).toDouble();
    return Container(
      height: 150,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.brightBlack),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'wterm@example:~ \$ ssh deploy@server',
            style: TextStyle(
              color: theme.green,
              fontFamily: terminalFont.isEmpty ? 'Menlo' : terminalFont,
              fontSize: size,
            ),
          ),
          Text(
            'Connected. Last login: today',
            style: TextStyle(
              color: theme.foreground,
              fontFamily: terminalFont.isEmpty ? 'Menlo' : terminalFont,
              fontSize: size,
            ),
          ),
          Text(
            'deploy@server:~\$ echo ready',
            style: TextStyle(
              color: theme.cyan,
              fontFamily: terminalFont.isEmpty ? 'Menlo' : terminalFont,
              fontSize: size,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _stepContent() => switch (step) {
    0 => [
      const Text('外观可以随时在设置中修改。皮肤会同时调整界面与终端配色。'),
      const SizedBox(height: 12),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'system', label: Text('跟随系统')),
          ButtonSegment(value: 'dark', label: Text('深色')),
          ButtonSegment(value: 'light', label: Text('浅色')),
        ],
        selected: {uiTheme},
        onSelectionChanged: (value) => setState(() => uiTheme = value.first),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: skin,
        decoration: const InputDecoration(labelText: '皮肤'),
        items: [
          const DropdownMenuItem(value: 'none', child: Text('不使用皮肤')),
          for (final entry in builtInSkins.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value.name)),
        ],
        onChanged: (value) => setState(() => skin = value ?? 'none'),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in TerminalAppearance.names.entries)
            ChoiceChip(
              label: Text(entry.value),
              selected: palette == entry.key,
              onSelected: (_) => setState(() => palette = entry.key),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _terminalPreview(),
    ],
    1 => [
      const Text('终端字体默认使用 Menlo，也可以从已安装字体中选择。'),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: terminalFont,
        decoration: const InputDecoration(labelText: '终端字体'),
        items: [
          const DropdownMenuItem(value: '', child: Text('Menlo（默认）')),
          for (final font in widget.fontChoices)
            DropdownMenuItem(value: font, child: Text(font)),
        ],
        onChanged: (value) => setState(() => terminalFont = value ?? ''),
      ),
      const SizedBox(height: 10),
      Text('字号：$fontSize'),
      Slider(
        min: 10,
        max: 28,
        divisions: 18,
        value: fontSize.toDouble(),
        label: '$fontSize',
        onChanged: (value) => setState(() => fontSize = value.round()),
      ),
      _terminalPreview(),
    ],
    2 => [
      const Text('这些开关也位于 设置 → 常规 与 设置 → 插件。'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: copyOnSelect,
        onChanged: (value) => setState(() => copyOnSelect = value),
        title: const Text('选中即复制'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: linkUnderline,
        onChanged: (value) => setState(() => linkUnderline = value),
        title: const Text('识别并标注链接'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: dragUpload,
        onChanged: (value) => setState(() => dragUpload = value),
        title: const Text('拖拽上传'),
      ),
    ],
    3 => [
      const Text('插件可以随时在 设置 → 插件 中调整。'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: completion,
        onChanged: (value) => setState(() => completion = value),
        title: const Text('命令补全'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: filePreview,
        onChanged: (value) => setState(() => filePreview = value),
        title: const Text('文件预览'),
        subtitle: const Text('Cmd/Ctrl + 点击终端内路径预览文件'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: ipLookup,
        onChanged: (value) => setState(() => ipLookup = value),
        title: const Text('IP 归属查询'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: jsonFormatter,
        onChanged: (value) => setState(() => jsonFormatter = value),
        title: const Text('JSON 格式化'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: notifications,
        onChanged: (value) => setState(() => notifications = value),
        title: const Text('任务完成通知'),
      ),
    ],
    _ => [
      const Text('GitHub 私有仓库同步使用端到端加密，连接、身份、片段、设置与 AI 环境只保存在本机与私有仓库。'),
      const SizedBox(height: 12),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.lock_outline),
        title: Text('同步密钥仅保存在本机'),
        subtitle: Text('丢失同步密钥后，云端历史数据无法解密。'),
      ),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.sync_outlined),
        title: Text('配置入口'),
        subtitle: Text('设置 → 同步 → GitHub 同步，可创建或接入私有仓库。'),
      ),
      const SizedBox(height: 8),
      const Text('可以现在跳过，之后在设置中随时开启。'),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final last = step == 4;
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text('欢迎使用 W Term · ${step + 1}/5'),
          actions: [
            TextButton(
              key: const ValueKey('onboarding-skip'),
              onPressed: busy ? null : skip,
              child: const Text('跳过'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: (step + 1) / 5),
                  const SizedBox(height: 18),
                  Text(
                    _titles[step],
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: _stepContent(),
                    ),
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      if (step > 0)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() => step--),
                          child: const Text('上一步'),
                        ),
                      const Spacer(),
                      FilledButton(
                        key: ValueKey(
                          last ? 'onboarding-finish' : 'onboarding-next',
                        ),
                        onPressed: busy
                            ? null
                            : last
                            ? finish
                            : () => setState(() => step++),
                        child: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(last ? '完成' : '下一步'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
