import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/folder_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  test(
    'macOS bookmark is retained for retries and released after active transfer',
    () async {
      final nativeCalls = <String>[];
      const channel = MethodChannel('desktop_drop');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            nativeCalls.add(call.method);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final access = await FolderAccess.fromDrop(
        DropItemDirectory(
          '/folder',
          [],
          extraAppleBookmark: Uint8List.fromList([1, 2]),
        ),
      );
      access.retain();
      await access.release();
      expect(nativeCalls, ['startAccessingSecurityScopedResource']);
      await access.release();
      await access.release();
      expect(nativeCalls, [
        'startAccessingSecurityScopedResource',
        'stopAccessingSecurityScopedResource',
      ]);
      expect(calls, isEmpty);
    },
  );
  test('macOS denied bookmark never produces usable scope', () async {
    const channel = MethodChannel('desktop_drop');
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return false;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await expectLater(
      FolderAccess.fromDrop(
        DropItemDirectory(
          '/folder',
          [],
          extraAppleBookmark: Uint8List.fromList([1]),
        ),
      ),
      throwsStateError,
    );
    expect(methods, ['startAccessingSecurityScopedResource']);
  });
  test(
    'container drop without bookmark needs no platform authorization',
    () async {
      final access = await FolderAccess.fromDrop(
        DropItemDirectory('/container/folder', []),
      );
      expect(access.path, '/container/folder');
      await access.release();
      expect(calls, isEmpty);
    },
  );
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FolderAccess.channel, (call) async {
          calls.add(call);
          if (call.method == 'pick') {
            return {'path': '/selected/目录', 'token': 'scope-1'};
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FolderAccess.channel, null),
  );
  test('picker returns directory scope and releases exactly once', () async {
    final access = (await FolderAccess.pick())!;
    expect(access.path, '/selected/目录');
    await access.release();
    await access.release();
    expect(calls.map((c) => c.method), ['pick', 'release']);
    expect(calls.last.arguments, 'scope-1');
    expect(access.retain, throwsStateError);
  });
  test(
    'closing owner during transfer defers release until transfer ends',
    () async {
      final access = (await FolderAccess.pick())!;
      access.retain();
      await access.release();
      expect(calls.length, 1);
      await access.release();
      expect(calls.last.method, 'release');
    },
  );
  test('completed transfer keeps owner scope for retry', () async {
    final access = (await FolderAccess.pick())!;
    for (var i = 0; i < 2; i++) {
      access.retain();
      await access.release();
      expect(calls.length, 1);
    }
    await access.release();
    expect(calls.length, 2);
  });
  test('cancelled picker returns no scope', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FolderAccess.channel, (_) async => null);
    expect(await FolderAccess.pick(), isNull);
  });
  test('native access denial reaches caller', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FolderAccess.channel, (_) async {
          throw PlatformException(code: 'access_denied', message: 'denied');
        });
    await expectLater(FolderAccess.pick(), throwsA(isA<PlatformException>()));
  });
}
