import 'dart:async';

import 'package:flutter/foundation.dart';

import 'plugins.dart';

class TaskCompletion {
  final String sessionId, title, command;
  final Duration elapsed;
  const TaskCompletion({
    required this.sessionId,
    required this.title,
    required this.command,
    required this.elapsed,
  });
}

class _TrackedTask {
  final String title, command;
  final DateTime startedAt;
  Timer? idle;
  _TrackedTask(this.title, this.command, this.startedAt);
}

/// Heuristically reports long commands after terminal output becomes idle.
/// Interactive programs are excluded so editors, pagers and remote shells do
/// not fire notifications merely because they wait for input.
class TaskMonitor extends ChangeNotifier {
  final DateTime Function() _now;
  final bool Function() _enabled;
  final Duration idleDelay, minimumDuration;
  final Map<String, _TrackedTask> _tasks = {};
  final List<TaskCompletion> _pending = [];

  TaskMonitor({
    DateTime Function()? now,
    bool Function()? enabled,
    this.idleDelay = const Duration(seconds: 3),
    this.minimumDuration = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now,
       _enabled = enabled ?? (() => pluginSettings.taskNotifications);

  static final _excluded = RegExp(
    r'^(vim|vi|nvim|nano|emacs|less|more|top|htop|btop|watch|tmux|screen|ssh|mosh|su|sudo|bash|sh|zsh|fish|python|python3|node|mysql|psql|redis-cli|sqlite3|sftp|ftp)(\s|$)',
  );
  static final _follow = RegExp(
    r'\b(tail|journalctl|docker\s+logs|kubectl\s+logs)\b.*\s-f(\s|$)',
  );

  List<TaskCompletion> drain() {
    final result = List<TaskCompletion>.unmodifiable(_pending);
    _pending.clear();
    return result;
  }

  bool _notifiable(String command) {
    final value = command.trim();
    if (value.isEmpty || value.length > 2000) return false;
    if (_excluded.hasMatch(value)) return false;
    if (_follow.hasMatch(value)) return false;
    if (value.endsWith('&')) return false;
    return true;
  }

  void commandSubmitted(
    String sessionId,
    String command, {
    required String title,
  }) {
    final current = _tasks.remove(sessionId);
    current?.idle?.cancel();
    if (!_enabled() || !_notifiable(command)) return;
    _tasks[sessionId] = _TrackedTask(title, command.trim(), _now());
  }

  void activity(String sessionId) {
    if (!_enabled()) return;
    final task = _tasks[sessionId];
    if (task == null) return;
    task.idle?.cancel();
    task.idle = Timer(idleDelay, () => _finish(sessionId));
  }

  void _finish(String sessionId) {
    final task = _tasks.remove(sessionId);
    if (task == null) return;
    final elapsed = _now().difference(task.startedAt);
    if (elapsed < minimumDuration) return;
    _pending.add(
      TaskCompletion(
        sessionId: sessionId,
        title: task.title,
        command: task.command,
        elapsed: elapsed,
      ),
    );
    notifyListeners();
  }

  void sessionClosed(String sessionId) {
    _tasks.remove(sessionId)?.idle?.cancel();
  }

  void cancelAll() {
    for (final task in _tasks.values) {
      task.idle?.cancel();
    }
    _tasks.clear();
    _pending.clear();
  }
}

final taskMonitor = TaskMonitor();
