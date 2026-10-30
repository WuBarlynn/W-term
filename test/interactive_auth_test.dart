import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/interactive_auth.dart';
import 'package:wterm/features/auth_challenge_dialog.dart';
import 'package:wterm/src/rust/api/client.dart';

const challenge = AuthChallenge(
  id: 'round-1',
  name: 'MFA',
  instructions: 'Enter test code',
  prompts: [
    AuthPrompt(label: 'Code', echo: false),
    AuthPrompt(label: 'Label', echo: true),
  ],
);
Future<void> open(
  WidgetTester t,
  Future<void> ended,
  void Function(List<String>?) result, {
  AuthChallenge c = challenge,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result(
                await showDialog<List<String>>(
                  context: context,
                  builder: (_) => AuthChallengeDialog(
                    challenge: c,
                    endpoint: 'tester@host:22',
                    finished: ended,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('server echo flags and transient answers match each prompt', (
    t,
  ) async {
    final ended = Completer<void>();
    List<String>? answer;
    await open(t, ended.future, (a) => answer = a);
    final fields = find.byType(TextField);
    expect(t.widget<TextField>(fields.first).obscureText, isTrue);
    expect(t.widget<TextField>(fields.last).obscureText, isFalse);
    await t.enterText(fields.first, '654321');
    await t.enterText(fields.last, 'visible');
    await t.tap(find.text('继续'));
    await t.pumpAndSettle();
    expect(answer, ['654321', 'visible']);
  });
  testWidgets('authentication end closes only its own prompt on phone', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 700);
    t.view.devicePixelRatio = 1;
    t.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetViewInsets);
    final ended = Completer<void>();
    List<String>? answer = ['not returned'];
    await open(t, ended.future, (a) => answer = a);
    await t.enterText(find.byType(TextField).first, 'temporary');
    ended.complete();
    await t.pumpAndSettle();
    expect(answer, isNull);
    expect(find.text('open'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'zero prompts require explicit continuation and cancel returns nothing',
    (t) async {
      List<String>? answer;
      final ended = Completer<void>();
      await open(
        t,
        ended.future,
        (a) => answer = a,
        c: const AuthChallenge(
          id: 'empty',
          name: '',
          instructions: 'Confirm',
          prompts: [],
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await t.tap(find.text('继续'));
      await t.pumpAndSettle();
      expect(answer, isEmpty);
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消连接'));
      await t.pumpAndSettle();
      expect(answer, isNull);
    },
  );
  test(
    'orchestrator clears responses and does not replay after completion',
    () async {
      final auth = Completer<String>();
      var asks = 0, replies = 0;
      final answers = ['123', 'label'];
      final user = await runInteractiveAuthentication(
        authenticate: () => auth.future,
        poll: () async => challenge,
        reply: (id, a) async {
          expect(id, 'round-1');
          expect(a, ['123', 'label']);
          replies++;
          auth.complete('tester');
        },
        cancel: () async {},
        ask: (c, done) async {
          asks++;
          return answers;
        },
      );
      expect(user, 'tester');
      expect(asks, 1);
      expect(replies, 1);
      expect(answers, isEmpty);
    },
  );
  test('cancel and native failure return errors without leaving authentication running', () async {
    final auth = Completer<String>();
    var cancels = 0;
    await expectLater(
      runInteractiveAuthentication(
        authenticate: () => auth.future,
        poll: () async => challenge,
        reply: (_, _) async {},
        cancel: () async {
          cancels++;
          if (!auth.isCompleted) auth.completeError(StateError('cancelled'));
        },
        ask: (_, _) async => null,
      ),
      throwsStateError,
    );
    expect(cancels, 1);
    await expectLater(
      runInteractiveAuthentication(
        authenticate: () async => throw StateError('timeout'),
        poll: () async => null,
        reply: (_, _) async {},
        cancel: () async {},
        ask: (_, _) async => null,
      ),
      throwsStateError,
    );
  });
}
