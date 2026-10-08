import 'dart:io';

/// Explicit inputs avoid the upstream dep-info parser splitting escaped spaces
/// in paths such as "W term". Track source directories too, for new modules.
Iterable<Uri> rustBuildInputs(Uri packageRoot) sync* {
  for (final path in [
    'rust/Cargo.toml',
    'rust/Cargo.lock',
    'rust/build.rs',
    '.cargo/config.toml',
  ]) {
    final file = File.fromUri(packageRoot.resolve(path));
    if (file.existsSync()) yield file.uri;
  }
  final sources = Directory.fromUri(packageRoot.resolve('rust/src/'));
  if (!sources.existsSync()) return;
  yield sources.uri;
  for (final entry in sources.listSync(recursive: true, followLinks: false)) {
    if (entry is File || entry is Directory) yield entry.uri;
  }
}
