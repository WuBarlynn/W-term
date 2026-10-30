import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/snippet_catalog.dart';
import 'package:wterm/app/snippet_store.dart';

void main() {
  test('official snippet catalog is unique and contains valid commands', () {
    expect(snippetCatalog.length, greaterThanOrEqualTo(24));
    expect(
      snippetCatalog.map((entry) => entry.name).toSet().length,
      snippetCatalog.length,
    );
    for (final entry in snippetCatalog) {
      expect(entry.category, isNotEmpty);
      expect(validateSnippetCommand(entry.command), isNull, reason: entry.name);
    }
  });
}
