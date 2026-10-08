import 'package:flutter/material.dart';

import '../app/errors.dart';

class RemotePermissionsDialog extends StatefulWidget {
  final String name;
  final int permissions;
  final Future<void> Function(int) onSave;
  const RemotePermissionsDialog({
    super.key,
    required this.name,
    required this.permissions,
    required this.onSave,
  });
  @override
  State<RemotePermissionsDialog> createState() =>
      _RemotePermissionsDialogState();
}

class _RemotePermissionsDialogState extends State<RemotePermissionsDialog> {
  final form = GlobalKey<FormState>();
  late int mode = widget.permissions & 511;
  late final input = TextEditingController(
    text: mode.toRadixString(8).padLeft(3, '0'),
  );
  bool busy = false;
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    final value = int.parse(input.text, radix: 8);
    if (value == (widget.permissions & 511)) {
      Navigator.pop(context, false);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSave(value);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('文件权限'),
      scrollable: true,
      content: SizedBox(
        width: 380,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.name),
              const SizedBox(height: 12),
              TextFormField(
                controller: input,
                enabled: !busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '八进制权限',
                  helperText: '例如：644 为所有者可读写，其他人只读',
                ),
                validator: (v) =>
                    v == null || !RegExp(r'^[0-7]{3}$').hasMatch(v)
                    ? '请输入 000 至 777 的三位权限'
                    : null,
                onChanged: (v) {
                  if (RegExp(r'^[0-7]{3}$').hasMatch(v)) {
                    setState(() => mode = int.parse(v, radix: 8));
                  }
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(child: SizedBox()),
                  for (final title in ['读', '写', '执行'])
                    SizedBox(width: 48, child: Center(child: Text(title))),
                ],
              ),
              for (var role = 0; role < 3; role++)
                Row(
                  children: [
                    Expanded(child: Text(['所有者', '用户组', '其他人'][role])),
                    for (var bit = 0; bit < 3; bit++)
                      SizedBox(
                        width: 48,
                        child: Checkbox(
                          key: ValueKey('permission-$role-$bit'),
                          value: mode & (1 << (8 - role * 3 - bit)) != 0,
                          onChanged: busy
                              ? null
                              : (checked) => setState(() {
                                  final mask = 1 << (8 - role * 3 - bit);
                                  mode = checked! ? mode | mask : mode & ~mask;
                                  input.text = mode
                                      .toRadixString(8)
                                      .padLeft(3, '0');
                                }),
                        ),
                      ),
                  ],
                ),
              if (widget.permissions & 3584 != 0) const Text('已设置的特殊权限位将保留。'),
              const Text('仅修改当前项目，不递归修改文件夹内容。', style: TextStyle(fontSize: 12)),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: busy ? null : save, child: const Text('保存')),
      ],
    ),
  );
}
