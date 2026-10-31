class SyncProfile {
  final bool configured, tokenSaved, initialized, recoveryConfirmed, pending;
  final String owner, repository, branch, revision;
  const SyncProfile({
    this.configured = false,
    this.tokenSaved = false,
    this.initialized = false,
    this.recoveryConfirmed = false,
    this.pending = false,
    this.owner = '',
    this.repository = '',
    this.branch = 'main',
    this.revision = '',
  });
}

abstract interface class SyncedSettingsHost {
  void attachSyncedSettings({
    required Future<String> Function() exportSettings,
    required Future<void> Function(String json) importSettings,
  });
}

abstract interface class SyncStore {
  Future<SyncDisconnectInfo> disconnectPreview();
  Future<void> disconnectSync(String revision, String confirmation);
  Future<SyncScopeView> syncScope([List<SyncScopeKey>? selection]);
  Future<void> saveSyncScope(String revision, List<SyncScopeKey> selection);
  Future<SyncProfile> syncSettings();
  Future<void> saveSyncSettings(
    String owner,
    String repository,
    String branch,
    String accessToken,
  );
  Future<String> checkSync();
  Future<String> initializeSync(String mode, String secret);
  Future<void> confirmSyncRecovery(String code);
  Future<String> runSync();
  Future<String> adoptSyncKey(String mode, String secret);
  Future<SyncReview?> syncConflicts();
  Future<String> resolveSync(String reviewId, List<SyncChoice> choices);
  Future<void> cancelSync();
  Future<SyncRotation> rotationStatus();
  Future<String> beginRotation(String password);
  Future<void> confirmRotation(String batchId, String code);
  Future<void> discardRotation(String batchId);
  Future<String> publishRotation(String batchId);
}

class SyncConflictEntry {
  final String kind, id, localSummary, remoteSummary;
  final bool localDeleted, remoteDeleted;
  final List<String> changedFields;
  const SyncConflictEntry({
    required this.kind,
    required this.id,
    required this.localSummary,
    required this.remoteSummary,
    required this.localDeleted,
    required this.remoteDeleted,
    required this.changedFields,
  });
}

class SyncReview {
  final String id;
  final List<SyncConflictEntry> items;
  const SyncReview(this.id, this.items);
}

class SyncChoice {
  final String kind, id, side;
  const SyncChoice(this.kind, this.id, this.side);
}

class SyncRotation {
  final bool canBegin, recoveryConfirmed, canDiscard;
  final String batchId;
  bool get active => batchId.isNotEmpty;
  const SyncRotation({
    this.canBegin = false,
    this.batchId = '',
    this.recoveryConfirmed = false,
    this.canDiscard = false,
  });
}

class SyncScopeKey {
  final String kind, id;
  const SyncScopeKey(this.kind, this.id);
  @override
  bool operator ==(Object other) =>
      other is SyncScopeKey && kind == other.kind && id == other.id;
  @override
  int get hashCode => Object.hash(kind, id);
}

class SyncScopeItem {
  final SyncScopeKey key;
  final String summary;
  final bool selected, excluded, published;
  const SyncScopeItem(
    this.key,
    this.summary, {
    this.selected = false,
    this.excluded = false,
    this.published = false,
  });
}

class SyncScopeView {
  final String revision, blockedReason;
  final List<SyncScopeItem> items;
  const SyncScopeView(this.revision, this.items, {this.blockedReason = ''});
}

class SyncDisconnectInfo {
  final String revision, target, blockedReason;
  final bool initialized;
  const SyncDisconnectInfo(
    this.revision,
    this.target, {
    this.initialized = false,
    this.blockedReason = '',
  });
}
