import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/shortcuts.dart';

void main() {
  test('default shortcuts match the platform modifier layout', () {
    final mac = ShortcutSettings(apple: true, initial: null);
    expect(mac.bindings['new']!.meta, isTrue);
    expect(mac.bindings['new']!.control, isFalse);
    expect(mac.bindings['new']!.shift, isFalse);
    final windows = ShortcutSettings(apple: false);
    expect(windows.bindings['new']!.control, isTrue);
    expect(windows.bindings['new']!.shift, isTrue);
    expect(
      windows.match(
        keyId: LogicalKeyboardKey.keyT.keyId,
        metaPressed: false,
        controlPressed: true,
        shiftPressed: true,
        altPressed: false,
      ),
      'new',
    );
  });

  test('custom bindings persist, disable and reset', () async {
    final dir = await Directory.systemTemp.createTemp('wterm-shortcuts');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/shortcuts.json');
    final store = ShortcutSettings(apple: true, file: () async => file);
    const custom = ShortcutKey(
      keyId: 0x100000104,
      meta: true,
      shift: true,
    );
    await store.set('new', custom);
    expect(
      store.match(
        keyId: 0x100000104,
        metaPressed: true,
        controlPressed: false,
        shiftPressed: true,
        altPressed: false,
      ),
      'new',
    );
    await store.set(
      'new',
      const ShortcutKey(keyId: 0x100000104, meta: true, enabled: false),
    );
    expect(
      store.match(
        keyId: 0x100000104,
        metaPressed: true,
        controlPressed: false,
        shiftPressed: false,
        altPressed: false,
      ),
      isNull,
    );
    final restored = ShortcutSettings(apple: true, file: () async => file);
    await restored.load();
    expect(restored.bindings['new']!.enabled, isFalse);
    await restored.reset();
    expect(restored.bindings['new']!.enabled, isTrue);
    expect(restored.bindings['new']!.shift, isFalse);
  });
}
