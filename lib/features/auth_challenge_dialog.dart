import 'package:flutter/material.dart';

import '../src/rust/api/client.dart' show AuthChallenge;

class AuthChallengeDialog extends StatefulWidget {
  final AuthChallenge challenge;
  final String endpoint;
  final Future<void> finished;
  const AuthChallengeDialog({
    super.key,
    required this.challenge,
    required this.endpoint,
    required this.finished,
  });
  @override
  State<AuthChallengeDialog> createState() => _AuthChallengeDialogState();
}

class _AuthChallengeDialogState extends State<AuthChallengeDialog> {
  late final inputs = [
    for (final _ in widget.challenge.prompts) TextEditingController(),
  ];
  @override
  void initState() {
    super.initState();
    widget.finished.then((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    for (final input in inputs) {
      input.clear();
      input.dispose();
    }
    super.dispose();
  }

  void submit() {
    final answers = [for (final c in inputs) c.text];
    for (final c in inputs) {
      c.clear();
    }
    Navigator.pop(context, answers);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.challenge;
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.all(16),
      title: const Text('服务器交互式认证'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.endpoint),
            const SizedBox(height: 12),
            const Text('以下内容由已验证指纹的 SSH 服务器提供。回答仅用于本次认证，不会保存或同步。'),
            if (c.name.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(c.name),
              ),
            if (c.instructions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(c.instructions),
              ),
            for (var i = 0; i < c.prompts.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: TextField(
                  controller: inputs[i],
                  obscureText: !c.prompts[i].echo,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 16384,
                  decoration: InputDecoration(
                    labelText: c.prompts[i].label.isEmpty
                        ? '回答 ${i + 1}'
                        : c.prompts[i].label,
                    counterText: '',
                  ),
                  onSubmitted: i == c.prompts.length - 1
                      ? (_) => submit()
                      : null,
                ),
              ),
            if (c.prompts.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('服务器没有要求输入，点击继续确认此轮认证。'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消连接'),
        ),
        FilledButton(onPressed: submit, child: const Text('继续')),
      ],
    );
  }
}
