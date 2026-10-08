import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../hook/rust_inputs.dart';

void main() {
  test(
    'native build tracks real paths with spaces and newly added modules',
    () {
      final dir = Directory.systemTemp.createTempSync('W term build inputs ');
      addTearDown(() => dir.deleteSync(recursive: true));
      void create(String path) {
        final file = File.fromUri(dir.uri.resolve(path));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('fixture');
      }

      create('rust/Cargo.toml');
      create('rust/Cargo.lock');
      create('.cargo/config.toml');
      create('rust/src/lib.rs');
      create('rust/src/sync/github.rs');
      create('rust/target/generated');
      final before = rustBuildInputs(dir.uri).toSet();
      expect(before, contains(dir.uri.resolve('rust/src/sync/github.rs')));
      expect(before, contains(dir.uri.resolve('rust/src/sync/')));
      expect(before, contains(dir.uri.resolve('rust/Cargo.lock')));
      expect(before, contains(dir.uri.resolve('.cargo/config.toml')));
      expect(before.any((uri) => uri.path.contains('/target/')), isFalse);
      expect(
        before.every(
          (uri) =>
              FileSystemEntity.typeSync(uri.toFilePath()) !=
              FileSystemEntityType.notFound,
        ),
        isTrue,
      );
      create('rust/src/sync/new_module.rs');
      expect(
        rustBuildInputs(dir.uri),
        contains(dir.uri.resolve('rust/src/sync/new_module.rs')),
      );
    },
  );
}
