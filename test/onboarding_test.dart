import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/onboarding.dart';
import 'package:wterm/app/plugins.dart';
import 'package:wterm/app/terminal_appearance.dart';
import 'package:wterm/features/onboarding_dialog.dart';

void main() {
  test('onboarding marker persists completion', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-onboarding');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/onboarding.json');
    final store = OnboardingStore(file: () async => file);
    await store.load();
    expect(store.completed, isFalse);
    await store.complete();
    final restored = OnboardingStore(file: () async => file);
    await restored.load();
    expect(restored.completed, isTrue);
  });

  testWidgets('five-step onboarding navigates and exposes completion', (tester) async {
    final dir = Directory.systemTemp.createTempSync('wterm-onboarding');
    addTearDown(() => dir.deleteSync(recursive: true));
    final appearance = TerminalAppearance(
      file: () async => File('${dir.path}/appearance.json'),
    );
    final plugins = PluginSettings(
      file: () async => File('${dir.path}/plugins.json'),
    );
    final store = OnboardingStore(
      file: () async => File('${dir.path}/onboarding.json'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => OnboardingDialog(
                  appearance: appearance,
                  plugins: plugins,
                  store: store,
                  fontChoices: const ['Menlo', 'Consolas'],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('1/5'), findsOneWidget);
    await tester.tap(find.text('深色'));
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump();
    expect(find.textContaining('2/5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump();
    expect(find.textContaining('3/5'), findsOneWidget);
    await tester.tap(find.text('选中即复制'));
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump();
    expect(find.textContaining('4/5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump();
    expect(find.textContaining('5/5'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-finish')), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(appearance.copyOnSelect, isFalse);
    expect(store.completed, isFalse);
  });
}
