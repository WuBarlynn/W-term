import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_dialog_test.dart' show MemorySync, show, tap;

Future<void> expand(WidgetTester tester, MemorySync store) async {
  await show(tester, store);
  await tap(tester, find.text('接入新同步密钥'));
}

void main() {
  testWidgets(
    'adoption requires confirmation, clears secret, and does not sync',
    (tester) async {
      final store = MemorySync()..ready();
      await expand(tester, store);
      final button = find.widgetWithText(OutlinedButton, '验证并接入新密钥');
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      final field = find.widgetWithText(TextField, '输入新同步口令');
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.enterText(field, 'new test secret');
      await tap(tester, find.text('确认接入另一台设备轮换后的密钥'));
      await tap(tester, button);
      expect(store.adoptedMode, 'password');
      expect(store.adoptedSecret, 'new test secret');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(store.runs, 0);
      expect(find.text('新密钥已接入，请点击立即同步'), findsOneWidget);
    },
  );

  testWidgets(
    'mode switch clears credential and confirmation; failure can retry',
    (tester) async {
      final store = MemorySync()
        ..ready()
        ..failAdoption = true;
      await expand(tester, store);
      await tester.enterText(
        find.widgetWithText(TextField, '输入新同步口令'),
        'must clear',
      );
      await tap(tester, find.text('确认接入另一台设备轮换后的密钥'));
      await tap(tester, find.byType(DropdownButtonFormField<String>).last);
      await tap(tester, find.text('新恢复码').last);
      final field = find.widgetWithText(TextField, '输入新恢复码');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      final button = find.widgetWithText(OutlinedButton, '验证并接入新密钥');
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await tester.enterText(field, 'test recovery code');
      await tap(tester, find.text('确认接入另一台设备轮换后的密钥'));
      await tap(tester, button);
      expect(store.adoptedMode, 'recovery');
      expect(find.textContaining('恢复码无效'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      store.failAdoption = false;
      await tester.enterText(field, 'valid test code');
      await tap(tester, button);
      expect(find.text('新密钥已接入，请点击立即同步'), findsOneWidget);
      expect(store.runs, 0);
    },
  );

  testWidgets('pending batch and unsaved settings disable adoption', (
    tester,
  ) async {
    final store = MemorySync()..ready(pending: true);
    await expand(tester, store);
    final button = find.widgetWithText(OutlinedButton, '验证并接入新密钥');
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    expect(find.textContaining('请先恢复待处理同步'), findsOneWidget);
    expect(store.adoptedMode, isNull);
    await tester.pumpWidget(const SizedBox());
    store.ready();
    await expand(tester, store);
    await tap(tester, find.text('确认接入另一台设备轮换后的密钥'));
    await tester.enterText(
      find.widgetWithText(TextField, 'GitHub 令牌'),
      'changed token',
    );
    await tester.pump();
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  });

  testWidgets('adoption cancellation keeps dialog available on small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemorySync()
      ..ready()
      ..operation = Completer<String>();
    await expand(tester, store);
    await tester.enterText(
      find.widgetWithText(TextField, '输入新同步口令'),
      'test secret',
    );
    await tap(tester, find.text('确认接入另一台设备轮换后的密钥'));
    final button = find.widgetWithText(OutlinedButton, '验证并接入新密钥');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消操作'));
    await tester.pumpAndSettle();
    expect(store.cancels, 1);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNotNull,
    );
    expect(store.runs, 0);
    expect(tester.takeException(), isNull);
  });
}
