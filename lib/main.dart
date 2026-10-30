import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/rust/frb_generated.dart';
import 'features/vault_gate.dart';
import 'app/terminal_appearance.dart';
import 'app/pinned_commands.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init();
    await terminalAppearance.load();
    await pinnedCommands.load();
    runApp(const WTermApp());
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
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff167768),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: terminalAppearance.uiFont.trim().isNotEmpty
          ? terminalAppearance.uiFont.trim()
          : (windows ? 'Microsoft YaHei' : null),
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xfffafbfc)
          : const Color(0xff171c22),
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
    builder: (context, _) => MaterialApp(
      title: 'W Term',
      builder: (context, child) => VaultPrivacyShield(child: child!),
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: switch (terminalAppearance.uiTheme) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
      home: home ?? const VaultGate(),
    ),
  );
}
