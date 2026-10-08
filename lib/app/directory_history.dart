/// Session-only canonical SFTP paths. Commit only after a successful listing.
class DirectoryHistory {
  final int limit;
  final List<String> _paths = [];
  int _index = -1;
  DirectoryHistory({this.limit = 100}) : assert(limit > 0);
  List<String> get paths => List.unmodifiable(_paths);
  int get index => _index;
  String? get current => _index < 0 ? null : _paths[_index];
  int? get backIndex => _index > 0 ? _index - 1 : null;
  int? get forwardIndex => _index + 1 < _paths.length ? _index + 1 : null;

  void commit(String path, {int? historyIndex}) {
    if (historyIndex != null) {
      RangeError.checkValidIndex(historyIndex, _paths);
      _index = historyIndex;
      _paths[_index] = path;
      return;
    }
    if (current == path) return;
    _paths.removeRange(_index + 1, _paths.length);
    _paths.add(path);
    if (_paths.length > limit) _paths.removeAt(0);
    _index = _paths.length - 1;
  }
}
