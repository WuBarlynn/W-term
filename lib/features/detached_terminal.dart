import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/terminal_session.dart';
import 'terminal_pane.dart';

/// A macOS window that owns an SSH session handed off from the main workspace.
/// The Rust connection never disconnects during the handoff; only this view's
/// close button (or remote EOF) ends it.
class DetachedTerminalApp extends StatelessWidget {
  final Map<String, String> payload;
  const DetachedTerminalApp({super.key, required this.payload});

  ThemeData get _theme => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff167768),
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: const Color(0xff171c22),
    appBarTheme: const AppBarTheme(centerTitle: false),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: payload['title'] ?? 'W Term',
    debugShowCheckedModeBanner: false,
    theme: _theme,
    home: DetachedTerminalPage(payload: payload),
  );
}

class DetachedTerminalPage extends StatefulWidget {
  final Map<String, String> payload;
  const DetachedTerminalPage({super.key, required this.payload});

  @override
  State<DetachedTerminalPage> createState() => _DetachedTerminalPageState();
}

class _DetachedTerminalPageState extends State<DetachedTerminalPage> {
  static const _window = MethodChannel('dev.wterm/detached-window');
  late final TerminalSession session;
  bool closing = false;

  @override
  void initState() {
    super.initState();
    session = TerminalSession.attach(
      connectionId: widget.payload['connectionId']!,
      host: widget.payload['host'] ?? '',
      username: widget.payload['username'] ?? '',
      snapshot: widget.payload['snapshot'] ?? '',
      onEnded: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (closing) return;
    setState(() => closing = true);
    await session.close();
    try {
      await _window.invokeMethod<void>('close');
    } on PlatformException {
      // The native window may already be gone.
    } on MissingPluginException {
      // A non-macOS host cannot reach this page.
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = session.title;
    return Scaffold(
      body: Column(
        children: [
          Container(
            height: 40,
            color: const Color(0xff161c24),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(
                  Icons.open_in_new,
                  size: 16,
                  color: Color(0xffa5adba),
                ),
                const SizedBox(width: 8),
                const Text('独立窗口', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xffa5adba),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: closing ? null : close,
                  icon: const Icon(Icons.link_off, size: 16),
                  label: const Text('断开并关闭'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TerminalPane(
              session: session,
              active: true,
              onActivate: () {},
              onClosePane: close,
            ),
          ),
        ],
      ),
    );
  }
}
