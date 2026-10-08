import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/folder_upload.dart';

void main() {
  test(
    'hidden subtree exclusion reindexes parents without changing sources',
    () {
      final items = [
        FolderUploadItem('/root', 'root', true, null),
        FolderUploadItem('/root/.git', 'root/.git', true, 0),
        FolderUploadItem(
          '/root/.git/config',
          'root/.git/config',
          false,
          1,
          scannedBytes: 20,
        ),
        FolderUploadItem('/root/src', 'root/src', true, 0),
        FolderUploadItem(
          '/root/src/main',
          'root/src/main',
          false,
          3,
          scannedBytes: 10,
        ),
      ];
      final filtered = selectFolderUploadItems(items, includeHidden: false);
      expect(filtered.map((e) => e.relativePath), [
        'root',
        'root/src',
        'root/src/main',
      ]);
      expect(filtered.last.parentIndex, 1);
      expect(filtered.last.path, '/root/src/main');
      expect(filtered.last.scannedBytes, 10);
      expect(items.last.parentIndex, 3);
      expect(selectFolderUploadItems(items, includeHidden: true).length, 5);
    },
  );
  test('explicitly selected hidden root and empty folders are preserved', () {
    final filtered = selectFolderUploadItems([
      FolderUploadItem('/root', '.root', true, null),
      FolderUploadItem('/root/.secret', '.root/.secret', false, 0),
      FolderUploadItem('/root/empty', '.root/empty', true, 0),
    ], includeHidden: false);
    expect(filtered.map((e) => e.relativePath), ['.root', '.root/empty']);
    expect(filtered.last.parentIndex, 0);
  });

  test('remote root rename preserves source paths, hierarchy and sizes', () {
    final original = [
      FolderUploadItem('/local/root', 'root', true, null),
      FolderUploadItem(
        '/local/root/root.txt',
        'root/root.txt',
        false,
        0,
        scannedBytes: 7,
      ),
    ];
    final changed = renameUploadRoot(original, '备份 2');
    expect(changed.map((e) => e.relativePath), ['备份 2', '备份 2/root.txt']);
    expect(changed.last.path, original.last.path);
    expect(changed.last.parentIndex, 0);
    expect(changed.last.scannedBytes, 7);
    expect(original.first.relativePath, 'root');
  });
  test('remote root name rejects traversal and control characters', () {
    for (final name in [
      '',
      ' ',
      '.',
      '..',
      '../escape',
      '/root',
      'a\\b',
      'a\n',
    ]) {
      expect(validateUploadFolderName(name), isNotNull);
    }
    expect(validateUploadFolderName('备份 2'), isNull);
    expect(
      () => renameUploadRoot([FolderUploadItem('/a', 'a', true, null)], '../b'),
      throwsFormatException,
    );
    expect(
      () => renameUploadRoot([
        FolderUploadItem('/a', 'a', true, null),
        FolderUploadItem('/b', 'b', false, 0),
      ], 'new'),
      throwsFormatException,
    );
  });

  test('drop selection accepts one directory or multiple files but rejects mixed batches', () {
    final folder = DropItemDirectory('/folder', []);
    final file = DropItemFile('/a');
    expect(droppedFolder([folder]), same(folder));
    expect(droppedFolder([file, DropItemFile('/b')]), isNull);
    expect(() => droppedFolder([folder, file]), throwsFormatException);
    expect(
      () => droppedFolder([folder, DropItemDirectory('/other', [])]),
      throwsFormatException,
    );
  });

  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('wterm-folder-test-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  test(
    'plan preserves nested Unicode paths, hidden files and empty directories',
    () async {
      final root = await Directory('${temporary.path}/项目').create();
      await Directory('${root.path}/empty').create();
      await Directory('${root.path}/nested').create();
      await File('${root.path}/nested/中文.txt').writeAsString('hello');
      await File('${root.path}/.hidden').writeAsString('hidden');
      final plan = await planFolderUpload(root.path);
      expect(plan.map((e) => e.relativePath), [
        '项目',
        '项目/.hidden',
        '项目/empty',
        '项目/nested',
        '项目/nested/中文.txt',
      ]);
      expect(plan.fold<int>(0, (sum, item) => sum + item.scannedBytes), 11);
      expect(plan.first.scannedBytes, 0);
      expect(plan.first.parentIndex, isNull);
      expect(plan.last.parentIndex, 3);
      expect(plan[2].isDirectory, isTrue);
      expect(plan.last.isDirectory, isFalse);
      expect(await plan.last.readAsString(), 'hello');
    },
  );
  test('links are rejected without traversing outside root', () async {
    final root = await Directory('${temporary.path}/root').create();
    final outside = await File('${temporary.path}/secret')
        .writeAsString('private');
    await Link('${root.path}/link').create(outside.path);
    await expectLater(planFolderUpload(root.path), throwsFormatException);
    expect(await outside.readAsString(), 'private');
  });
  test('directory links and linked root are rejected', () async {
    final root = await Directory('${temporary.path}/root').create();
    await Link('${root.path}/loop').create(root.path);
    await expectLater(planFolderUpload(root.path), throwsFormatException);
    final alias = await Link('${temporary.path}/alias').create(root.path);
    await expectLater(planFolderUpload(alias.path), throwsFormatException);
  });
  test('depth and entry limits reject before any transfer', () async {
    final root = await Directory('${temporary.path}/root').create();
    await Directory('${root.path}/a/b').create(recursive: true);
    await expectLater(
      planFolderUpload(root.path, maxDepth: 1),
      throwsFormatException,
    );
    await expectLater(
      planFolderUpload(root.path, maxEntries: 2),
      throwsFormatException,
    );
  });
  test('cancel before scanning never returns a partial plan', () async {
    await expectLater(
      planFolderUpload(temporary.path, isCancelled: () => true),
      throwsA(isA<FolderScanCancelled>()),
    );
  });
  test('progress cancellation stops traversal and a new scan works', () async {
    final root = await Directory('${temporary.path}/root').create();
    await File('${root.path}/a').writeAsString('a');
    await File('${root.path}/b').writeAsString('b');
    var cancelled = false;
    final progress = <int>[];
    await expectLater(
      planFolderUpload(
        root.path,
        isCancelled: () => cancelled,
        onProgress: (count) {
          progress.add(count);
          if (count == 2) cancelled = true;
        },
      ),
      throwsA(isA<FolderScanCancelled>()),
    );
    expect(progress, [1, 2]);
    expect((await planFolderUpload(root.path)).length, 3);
  });
  test('missing root or file cannot become directory upload', () async {
    final file = await File('${temporary.path}/file').writeAsString('x');
    await expectLater(planFolderUpload(file.path), throwsFormatException);
    await expectLater(
      planFolderUpload('${temporary.path}/missing'),
      throwsFormatException,
    );
  });
}
