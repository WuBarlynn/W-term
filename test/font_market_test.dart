import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/features/font_market_dialog.dart';

void main() {
  test('catalog entries use unique names and HTTPS upstream URLs', () {
    expect(fontMarketCatalog.length, greaterThanOrEqualTo(5));
    final names = fontMarketCatalog.map((entry) => entry.name).toSet();
    expect(names.length, fontMarketCatalog.length);
    for (final entry in fontMarketCatalog) {
      expect(Uri.parse(entry.url).scheme, 'https');
      expect(entry.url, contains('githubusercontent.com'));
      expect(entry.description, isNotEmpty);
    }
  });

  testWidgets('font market installs a font and marks it installed', (
    tester,
  ) async {
    final installed = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FontMarketDialog(
            installed: const {},
            install: (entry) async => installed.add(entry.name),
          ),
        ),
      ),
    );
    expect(find.text('Fira Code'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('font-install-Fira Code')));
    await tester.pumpAndSettle();
    expect(installed, contains('Fira Code'));
    expect(find.text('已安装'), findsOneWidget);
  });

  testWidgets('font market reports a failed download', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FontMarketDialog(
            installed: const {},
            install: (_) async => throw StateError('network'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('font-install-Space Mono')));
    await tester.pumpAndSettle();
    expect(find.textContaining('安装失败'), findsOneWidget);
  });
}
