enum UploadConflictAction { replace, keepBoth, skip }

class UploadConflictChoice {
  final UploadConflictAction action;
  final bool applyToRemaining;
  const UploadConflictChoice(this.action, {this.applyToRemaining = false});
}

/// One upload attempt only: never retained across retries or separate batches.
class UploadConflictDecisions {
  UploadConflictAction? _remaining;

  Future<String?> resolve(
    Future<UploadConflictChoice?> Function() prompt,
  ) async {
    if (_remaining != null) return _remaining!.name;
    final choice = await prompt();
    if (choice == null) return null;
    if (choice.applyToRemaining) _remaining = choice.action;
    return choice.action.name;
  }
}
