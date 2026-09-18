import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/main.dart';
import 'package:wterm/app/workspace.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'desktop starts without mock hosts and opens a validated connection form',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const WTermApp(home: Workspace()));
      expect(find.text('你的服务器，触手可及。'), findsOneWidget);
      expect(find.text('服务器指纹'), findsOneWidget);
      await tester.tap(find.text('连接服务器'));
      await tester.pumpAndSettle();
      expect(find.text('新建 SSH 连接'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pumpAndSettle();
      expect(find.text('请输入主机地址'), findsOneWidget);
      expect(find.text('请输入用户名'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('phone and keyboard constrained form do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const WTermApp(home: Workspace()));
    await tester.tap(find.text('连接服务器'));
    await tester.pumpAndSettle();
    expect(find.text('新建 SSH 连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
