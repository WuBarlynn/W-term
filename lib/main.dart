import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/rust/frb_generated.dart';
import 'features/detached_terminal.dart';
import 'features/vault_gate.dart';
import 'app/deep_links.dart';
import 'app/system_notifications.dart';
import 'app/desktop_tray.dart';
import 'app/terminal_appearance.dart';
import 'app/pinned_commands.dart';
import 'app/plugins.dart';

Map<String, String>? detachedPayload(List<String> args) {
  final index = args.indexOf('--wterm-detached');
  if (index < 0 || index + 1 >= args.length) return null;
  try {
    final decoded = jsonDecode(args[index + 1]);
    if (decoded is! Map) return null;
    return decoded.map((key, value) => MapEntry('$key', '$value'));
  } catch (_) {
    return null;
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Map<String, String>? detached = detachedPayload(args);
  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
    } catch (_) {
      // The tray/window plugin is optional for the main window.
    }
    try {
      final controller = await WindowController.fromCurrentEngine();
      if (controller.arguments.isNotEmpty) {
        final decoded = jsonDecode(controller.arguments);
        if (decoded is Map) {
          detached = decoded.map((key, value) => MapEntry('$key', '$value'));
        }
      }
    } catch (_) {
      // A normal window has no multi-window definition; keep the workspace.
    }
  }
  try {
    await RustLib.init();
    await terminalAppearance.load();
    await pinnedCommands.load();
    await pluginSettings.load();
    runApp(
      detached == null
          ? const WTermApp()
          : DetachedTerminalApp(payload: detached),
    );
    if (detached == null) {
      unawaited(deepLinkService.start());
      if (pluginSettings.taskNotifications) {
        unawaited(systemNotifications.setup());
      }
      if (!Platform.isAndroid && !Platform.isIOS) {
        unawaited(desktopTray.setup());
      }
    }
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                'W Term 核心加载失败\n\n$error\n\n请参考 README 重新构建应用。',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WTermApp extends StatelessWidget {
  final Widget? home;
  const WTermApp({super.key, this.home});
  ThemeData theme(Brightness brightness) {
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final skin = builtInSkins[terminalAppearance.skin];
    final scheme = ColorScheme.fromSeed(
      seedColor: Color(skin?.seed ?? 0xff167768),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: terminalAppearance.uiFont.trim().isNotEmpty
          ? terminalAppearance.uiFont.trim()
          : (windows ? 'Microsoft YaHei' : null),
      scaffoldBackgroundColor: skin == null
          ? brightness == Brightness.light
                ? const Color(0xfffafbfc)
                : const Color(0xff171c22)
          : Colors.transparent,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: terminalAppearance,
    builder: (context, _) {
      final skin = builtInSkins[terminalAppearance.skin];
      final themeMode = skin == null
          ? switch (terminalAppearance.uiTheme) {
              'dark' => ThemeMode.dark,
              'light' => ThemeMode.light,
              _ => ThemeMode.system,
            }
          : skin.dark
          ? ThemeMode.dark
          : ThemeMode.light;
      return MaterialApp(
        title: 'W Term',
        builder: (context, child) {
          Widget content = VaultPrivacyShield(child: child!);
          if (skin != null) {
            content = DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(skin.top), Color(skin.bottom)],
                ),
              ),
              child: content,
            );
          }
          return content;
        },
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        themeMode: themeMode,
        home: home ?? const VaultGate(),
      );
    },
  );
}
