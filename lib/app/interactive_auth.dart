import 'dart:async';

import '../src/rust/api/client.dart' show AuthChallenge;

/// Polls only during authentication; answers never enter an identity or vault.
Future<String> runInteractiveAuthentication({
  required Future<String> Function() authenticate,
  required Future<AuthChallenge?> Function() poll,
  required Future<void> Function(String, List<String>) reply,
  required Future<void> Function() cancel,
  required Future<List<String>?> Function(AuthChallenge, Future<void>) ask,
}) async {
  final ended = Completer<void>();
  String? username;
  Object? failure;
  StackTrace? trace;
  final completed = Future<String>.sync(authenticate)
      .then<void>(
        (value) => username = value,
        onError: (Object e, StackTrace s) {
          failure = e;
          trace = s;
        },
      )
      .whenComplete(() => ended.complete());
  try {
    while (!ended.isCompleted) {
      await Future.any([
        Future<void>.delayed(const Duration(milliseconds: 200)),
        ended.future,
      ]);
      if (ended.isCompleted) break;
      final challenge = await poll();
      if (challenge == null || ended.isCompleted) continue;
      final answers = await ask(challenge, ended.future);
      if (ended.isCompleted) {
        answers?.clear();
        break;
      }
      if (answers == null) {
        throw StateError('认证已取消');
      }
      try {
        await reply(challenge.id, answers);
      } finally {
        answers.clear();
      }
    }
    await completed;
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return username!;
  } catch (_) {
    await cancel();
    await completed;
    rethrow;
  }
}
