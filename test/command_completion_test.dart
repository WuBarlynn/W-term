import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/command_completion.dart';

void main() {
  test('subcommand suggestions filter by the token being typed', () {
    final suggestions = commandSuggestions('git ch');
    expect(suggestions.map((entry) => entry.value), [
      'checkout',
      'cherry-pick',
    ]);
    expect(suggestions.every((entry) => entry.group == 'git'), isTrue);
    expect(commandInsertionFor('git ch', suggestions.first), 'eckout ');
  });

  test('group suggestions need a separator when the command is complete', () {
    final suggestions = commandSuggestions('git');
    expect(suggestions, isNotEmpty);
    expect(commandInsertionFor('git', suggestions.first), ' add ');
    expect(commandInsertionFor('git ', suggestions.first), 'add ');
  });

  test('top-level command names complete by prefix', () {
    final suggestions = commandSuggestions('doc');
    expect(suggestions.first.value, 'docker');
    expect(suggestions.first.group, isEmpty);
    expect(commandInsertionFor('doc', suggestions.first), 'ker ');
  });

  test('second-level docker compose arguments are supported', () {
    expect(commandSuggestions('docker compose u').map((entry) => entry.value), [
      'up',
    ]);
    expect(commandSuggestions('docker compose ').first.value, 'up');
  });

  test('unrelated arguments do not produce plugin suggestions', () {
    expect(commandSuggestions('git add src/'), isEmpty);
    expect(commandSuggestions('echo hello'), isEmpty);
    expect(commandSuggestions(''), isEmpty);
  });

  test('input tracker handles editing and hides after cursor movement', () {
    final tracker = TerminalInputTracker();
    tracker.feed('git ');
    tracker.feed('sta');
    expect(tracker.current, 'git sta');
    tracker.feed('\x7f');
    expect(tracker.current, 'git st');
    tracker.feed('\x1b[D');
    expect(tracker.current, isEmpty);
    tracker.feed('x');
    expect(tracker.current, isEmpty);
    tracker.feed('\r');
    tracker.feed('ls');
    expect(tracker.current, 'ls');
  });

  test('input tracker clears on Ctrl+U and Ctrl+C', () {
    final tracker = TerminalInputTracker();
    tracker.feed('echo hello');
    tracker.feed('\x15');
    expect(tracker.current, isEmpty);
    tracker.feed('git status');
    tracker.feed('\x03');
    expect(tracker.current, isEmpty);
  });
}

String commandInsertionFor(String input, CommandCompletion completion) =>
    completionInsertion(input, completion);
