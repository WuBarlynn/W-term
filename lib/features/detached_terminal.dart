import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app/session_handoff.dart';
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

class _DetachedTerminalPageState extends State<DetachedTerminalPage>
    with WindowListener {
  static const _window = MethodChannel('dev.wterm/detached-window');
  late TerminalSession session;
  bool closing = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) windowManager.addListener(this);
    session = TerminalSession.attach(
      connectionId: widget.payload['connectionId']!,
      host: widget.payload['host'] ?? '',
      username: widget.payload['username'] ?? '',
      snapshot: widget.payload['snapshot'] ?? '',
      hostId: widget.payload['hostId'] ?? '',
      onEnded: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    session.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(session.close());
  }

  Future<void> close() async {
    if (closing) return;
    setState(() => closing = true);
    await session.close();
    if (Platform.isWindows) {
      await windowManager.close();
      return;
    }
    try {
      await _window.invokeMethod<void>('close');
    } on PlatformException {
      // The native window may already be gone.
    } on MissingPluginException {
      // A non-macOS host cannot reach this page.
    }
  }

  Future<void> returnToMain() async {
    if (closing) return;
    setState(() => closing = true);
    String snapshot;
    try {
      snapshot = await session.detachForHandoff();
    } catch (e) {
      if (mounted) {
        setState(() => closing = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法收回会话：$e')));
      }
      return;
    }
    final payload = SessionHandoffPayload(
      connectionId: session.connectionId,
      host: session.host,
      username: session.username,
      hostId: session.hostId,
      snapshot: snapshot,
      title: session.title,
    );
    var accepted = false;
    try {
      if (Platform.isWindows) {
        accepted =
            await const WindowMethodChannel(
              'dev.wterm/window-recall',
              mode: ChannelMode.unidirectional,
            ).invokeMethod<bool>('recall', payload.encode()) ??
            false;
      } else {
        accepted =
            await _window.invokeMethod<bool>('returnToMain', {
              'payload': payload.encode(),
            }) ??
            false;
      }
    } catch (_) {
      // Fall through to reattach in this window.
    }
    if (!mounted) return;
    if (accepted) {
      session.dispose();
      if (Platform.isWindows) unawaited(windowManager.close());
      return;
    }
    session.dispose();
    session = TerminalSession.attach(
      connectionId: payload.connectionId,
      host: payload.host,
      username: payload.username,
      hostId: payload.hostId,
      snapshot: payload.snapshot,
      onEnded: () {
        if (mounted) setState(() {});
      },
    );
    setState(() => closing = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('收回失败，会话已保留在当前窗口')));
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
                  onPressed: closing ? null : returnToMain,
                  icon: const Icon(Icons.call_received, size: 16),
                  label: const Text('收回主窗口'),
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
