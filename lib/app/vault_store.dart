import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../src/rust/api/vault.dart' as native;
import 'host_store.dart';
import 'forward_store.dart';
import 'quick_unlock.dart';
import 'identity_store.dart';
import 'snippet_store.dart';
import 'sync_store.dart';
import 'onboarding.dart';
import 'proxy_store.dart';
import '../src/rust/api/client.dart' show ServerIdentity;
import '../src/rust/api/forward.dart' as forward_native;
import '../src/rust/api/proxy.dart' as proxy_native;
import '../src/rust/api/sync.dart' as sync_native;

abstract interface class VaultService {
  Future<bool> exists();
  Future<VaultSession> open(String password, {required bool create});
}

abstract interface class VaultSession implements HostStore, FolderStore {
  bool get legacyImported;
  Future<void> importLegacy(List<HostProfile> hosts, List<String> folders);
  Future<void> lock();
}

class NativeVaultService implements VaultService {
  Future<String> path() async {
    final root = await getApplicationSupportDirectory();
    await root.create(recursive: true);
    return '${root.path}/wterm-vault.db';
  }

  @override
  Future<bool> exists() async => File(await path()).exists();
  @override
  Future<VaultSession> open(String password, {required bool create}) async {
    final result = await native.vaultOpen(
      path: await path(),
      password: password,
      create: create,
    );
    return NativeVaultSession(result.token, result.legacyImported);
  }
}

class NativeVaultSession
    implements
        VaultSession,
        IdentityStore,
        FolderTreeStore,
        VaultMaintenance,
        KeyStore,
        PrivateKeyExportStore,
        SnippetStore,
        SyncStore,
        SyncedSettingsHost,
        FirstRunHost,
        ConnectionProxyStore,
        ForwardRuleStore {
  final String _token;
  final QuickUnlock _quick;
  Future<String> Function()? _exportSettings;
  Future<void> Function(String json)? _importSettings;
  @override
  final bool legacyImported;
  NativeVaultSession(
    this._token,
    this.legacyImported, {
    QuickUnlock? quickUnlock,
  }) : _quick = quickUnlock ?? QuickUnlock();
  @override
  void attachSyncedSettings({
    required Future<String> Function() exportSettings,
    required Future<void> Function(String json) importSettings,
  }) {
    _exportSettings = exportSettings;
    _importSettings = importSettings;
  }

  Future<void> _captureSettings() async {
    final export = _exportSettings;
    if (export == null) return;
    final json = await export();
    await native.vaultWrite(token: _token, kind: 'settings', json: json);
  }

  Future<void> _applySettings() async {
    final import = _importSettings;
    if (import == null) return;
    final json = await native.vaultRead(token: _token, kind: 'settings');
    if (json.trim().isEmpty) return;
    await import(json);
  }

  Future<T> _withSyncedSettings<T>(Future<T> Function() action) async {
    await _captureSettings();
    final result = await action();
    await _applySettings();
    return result;
  }

  @override
  Future<List<forward_native.ForwardRule>> forwardRules(String hostId) =>
      forward_native.forwardRules(token: _token, hostId: hostId);
  @override
  Future<forward_native.ForwardRule> saveForwardRule(
    forward_native.ForwardRule rule,
  ) => forward_native.forwardSaveRule(token: _token, rule: rule);
  @override
  Future<void> deleteForwardRule(String id) =>
      forward_native.forwardDeleteRule(token: _token, id: id);
  @override
  Future<proxy_native.ProxySettings> proxySettings() =>
      proxy_native.proxySettings(token: _token);
  @override
  Future<void> saveProxySettings(
    proxy_native.ProxySettings settings,
    String password,
  ) => proxy_native.proxySaveSettings(
    token: _token,
    settings: settings,
    password: password,
  );
  @override
  Future<List<proxy_native.ProxyProfile>> proxyProfiles() =>
      proxy_native.proxyProfiles(token: _token);
  @override
  Future<String> saveProxyProfile(
    proxy_native.ProxyProfileInput profile,
    String password,
  ) => proxy_native.proxySaveProfile(
    token: _token,
    profile: profile,
    password: password,
  );
  @override
  Future<void> deleteProxyProfile(String id) =>
      proxy_native.proxyDeleteProfile(token: _token, id: id);
  @override
  Future<String> hostProxyBinding(String hostId) =>
      proxy_native.proxyHostBinding(token: _token, hostId: hostId);
  @override
  Future<void> setHostProxyBinding(String hostId, String binding) =>
      proxy_native.proxySetHostBinding(
        token: _token,
        hostId: hostId,
        binding: binding,
      );
  @override
  Future<proxy_native.ProxyTestResult> testProxyGlobal(
    String targetHost,
    int targetPort,
  ) => proxy_native.proxyTestGlobal(
    token: _token,
    targetHost: targetHost,
    targetPort: targetPort,
  );
  @override
  Future<proxy_native.ProxyTestResult> testProxyProfile(
    String id,
    String targetHost,
    int targetPort,
  ) => proxy_native.proxyTestProfile(
    token: _token,
    id: id,
    targetHost: targetHost,
    targetPort: targetPort,
  );
  @override
  Future<proxy_native.ProxyTestResult> testProxyDraft(
    proxy_native.ProxyDraft draft,
    String password,
    String targetHost,
    int targetPort,
  ) => proxy_native.proxyTestDraft(
    draft: draft,
    password: password,
    targetHost: targetHost,
    targetPort: targetPort,
  );
  @override
  Future<ServerIdentity> probeWithHostProxy(
    String hostId,
    String host,
    int port, {
    String operationId = '',
  }) => proxy_native.probeServerWithHostProxy(
    token: _token,
    operationId: operationId,
    hostId: hostId,
    host: host,
    port: port,
  );
  @override
  Future<ServerIdentity> probeWithProxy(
    String host,
    int port, {
    String operationId = '',
  }) => proxy_native.probeServerWithProxy(
    token: _token,
    operationId: operationId,
    host: host,
    port: port,
  );
  @override
  Future<ServerIdentity> probeThrough(
    String parentConnectionId,
    String host,
    int port, {
    String operationId = '',
  }) => proxy_native.probeServerThrough(
    token: _token,
    operationId: operationId,
    parentConnectionId: parentConnectionId,
    host: host,
    port: port,
  );
  @override
  Future<void> cancelProbe(String operationId) =>
      proxy_native.cancelProbe(operationId: operationId);
  @override
  Future<List<HostProfile>> read() async =>
      (jsonDecode(await native.vaultRead(token: _token, kind: 'hosts')) as List)
          .map((v) => HostProfile.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
  @override
  Future<void> write(List<HostProfile> profiles) => native.vaultWrite(
    token: _token,
    kind: 'hosts',
    json: jsonEncode(profiles.map((h) => h.toJson()).toList()),
  );
  @override
  Future<List<String>> readFolders() async => List<String>.from(
    jsonDecode(await native.vaultRead(token: _token, kind: 'folders')) as List,
  );
  @override
  Future<void> writeFolders(List<String> folders) => native.vaultWrite(
    token: _token,
    kind: 'folders',
    json: jsonEncode(folders),
  );
  @override
  Future<void> importLegacy(List<HostProfile> hosts, List<String> folders) =>
      native.vaultImportLegacy(
        token: _token,
        hostsJson: jsonEncode(hosts.map((h) => h.toJson()).toList()),
        foldersJson: jsonEncode(folders),
      );
  @override
  Future<SyncProfile> syncSettings() async {
    final s = await sync_native.syncSettings(token: _token);
    return SyncProfile(
      configured: s.configured,
      tokenSaved: s.tokenSaved,
      initialized: s.initialized,
      recoveryConfirmed: s.recoveryConfirmed,
      pending: s.pending,
      owner: s.owner,
      repository: s.repository,
      branch: s.branch,
      revision: s.revision,
    );
  }

  @override
  Future<void> saveSyncSettings(
    String owner,
    String repository,
    String branch,
    String accessToken,
  ) => sync_native.syncSaveSettings(
    token: _token,
    owner: owner,
    repository: repository,
    branch: branch,
    accessToken: accessToken,
  );
  @override
  Future<String> checkSync() => sync_native.syncCheck(token: _token);
  @override
  Future<String> initializeSync(String mode, String secret) =>
      _withSyncedSettings(
        () => sync_native.syncInitialize(
          token: _token,
          mode: mode,
          secret: secret,
        ),
      );
  @override
  Future<void> confirmSyncRecovery(String code) => _withSyncedSettings(
    () => sync_native.syncConfirmRecovery(token: _token, code: code),
  );
  @override
  Future<String> runSync() =>
      _withSyncedSettings(() => sync_native.syncRun(token: _token));
  @override
  Future<SyncReview?> syncConflicts() async {
    final r = await sync_native.syncConflicts(token: _token);
    if (r == null) return null;
    return SyncReview(r.id, [
      for (final i in r.items)
        SyncConflictEntry(
          kind: i.kind,
          id: i.id,
          localSummary: i.localSummary,
          remoteSummary: i.remoteSummary,
          localDeleted: i.localDeleted,
          remoteDeleted: i.remoteDeleted,
          changedFields: i.changedFields,
        ),
    ]);
  }

  @override
  Future<String> resolveSync(String reviewId, List<SyncChoice> choices) =>
      _withSyncedSettings(
        () => sync_native.syncResolve(
          token: _token,
          reviewId: reviewId,
          choices: [
            for (final c in choices)
              sync_native.SyncConflictChoice(
                kind: c.kind,
                id: c.id,
                side: c.side,
              ),
          ],
        ),
      );
  @override
  Future<String> adoptSyncKey(String mode, String secret) => _withSyncedSettings(
    () => sync_native.syncAdoptKey(token: _token, mode: mode, secret: secret),
  );
  @override
  Future<void> cancelSync() => sync_native.syncCancel(token: _token);
  @override
  Future<SyncDisconnectInfo> disconnectPreview() async {
    final v = await sync_native.syncDisconnectPreview(token: _token);
    return SyncDisconnectInfo(
      v.revision,
      v.target,
      initialized: v.initialized,
      blockedReason: v.blockedReason,
    );
  }

  @override
  Future<void> disconnectSync(String revision, String confirmation) =>
      sync_native.syncDisconnect(
        token: _token,
        revision: revision,
        confirmation: confirmation,
      );
  @override
  Future<SyncScopeView> syncScope([List<SyncScopeKey>? selection]) async {
    final s = await sync_native.syncScope(
      token: _token,
      selection: selection
          ?.map((k) => sync_native.SyncScopeKey(kind: k.kind, id: k.id))
          .toList(),
    );
    return SyncScopeView(
      s.revision,
      s.items
          .map(
            (i) => SyncScopeItem(
              SyncScopeKey(i.kind, i.id),
              i.summary,
              selected: i.selected,
              excluded: i.excluded,
              published: i.published,
            ),
          )
          .toList(),
      blockedReason: s.blockedReason,
    );
  }

  @override
  Future<void> saveSyncScope(String revision, List<SyncScopeKey> selection) =>
      sync_native.syncSaveScope(
        token: _token,
        revision: revision,
        selection: selection
            .map((k) => sync_native.SyncScopeKey(kind: k.kind, id: k.id))
            .toList(),
      );
  @override
  Future<SyncRotation> rotationStatus() async {
    final s = await sync_native.syncRotationStatus(token: _token);
    return SyncRotation(
      canBegin: s.canBegin,
      batchId: s.batchId,
      recoveryConfirmed: s.recoveryConfirmed,
      canDiscard: s.canDiscard,
    );
  }

  @override
  Future<String> beginRotation(String password) =>
      sync_native.syncBeginRotation(token: _token, password: password);
  @override
  Future<void> confirmRotation(String batchId, String code) => sync_native
      .syncConfirmRotation(token: _token, batchId: batchId, code: code);
  @override
  Future<void> discardRotation(String batchId) =>
      sync_native.syncDiscardRotation(token: _token, batchId: batchId);
  @override
  Future<String> publishRotation(String batchId) =>
      sync_native.syncPublishRotation(token: _token, batchId: batchId);
  native.IdentityInput _input(IdentityDraft d) => native.IdentityInput(
    id: d.id,
    name: d.name,
    username: d.username,
    kind: d.kind,
    password: d.password,
    privateKey: d.privateKey,
    passphrase: d.passphrase,
    replaceSecret: d.replaceSecret,
  );
  @override
  Future<List<SavedIdentity>> identities() async =>
      (await native.vaultIdentities(token: _token))
          .map(
            (i) => SavedIdentity(
              id: i.id,
              name: i.name,
              username: i.username,
              kind: i.kind,
            ),
          )
          .toList();
  @override
  Future<String> saveIdentity(IdentityDraft draft) async {
    try {
      return await native.vaultSaveIdentity(
        token: _token,
        input: _input(draft),
      );
    } finally {
      draft.clear();
    }
  }

  @override
  Future<String> generateKey(String name, String username) =>
      native.vaultGenerateKey(token: _token, name: name, username: username);
  @override
  Future<String> publicKey(String id) =>
      native.vaultPublicKey(token: _token, id: id);
  @override
  Future<void> exportPrivateKey(String id, String path, String password) =>
      native.vaultExportPrivateKey(
        token: _token,
        id: id,
        path: path,
        password: password,
      );
  @override
  Future<void> deleteIdentity(String id) =>
      native.vaultDeleteIdentity(token: _token, id: id);
  @override
  Future<HostProfile> saveHost(
    HostProfile profile,
    IdentityDraft? draft,
  ) async {
    try {
      return HostProfile.fromJson(
        jsonDecode(
          await native.vaultSaveHost(
            token: _token,
            hostJson: jsonEncode(profile.toJson()),
            identity: draft == null ? null : _input(draft),
          ),
        ) as Map<String, dynamic>,
      );
    } finally {
      draft?.clear();
    }
  }

  @override
  Future<String> authenticateIdentity(
    String identityId,
    String connectionId,
    String fingerprint,
  ) => native.vaultAuthenticateIdentity(
    token: _token,
    identityId: identityId,
    connectionId: connectionId,
    approvedFingerprint: fingerprint,
  );
  @override
  Future<String> authenticateJumpIdentity(
    String identityId,
    String connectionId,
    String fingerprint,
  ) => native.vaultAuthenticateJumpIdentity(
    token: _token,
    identityId: identityId,
    connectionId: connectionId,
    approvedFingerprint: fingerprint,
  );
  @override
  Future<String> renameFolder(String path, String name) =>
      native.vaultRenameFolder(token: _token, path: path, name: name);
  @override
  Future<void> deleteFolder(String path, {bool deleteHosts = false}) => native
      .vaultDeleteFolder(token: _token, path: path, deleteHosts: deleteHosts);
  @override
  Future<void> changePassword(String current, String next) async {
    // Invalidate the old keychain credential before rekeying the database.
    // A crash between these operations must never leave quick unlock stale.
    if (await _quick.enabled()) await _quick.disable();
    await native.vaultChangePassword(
      token: _token,
      currentPassword: current,
      newPassword: next,
    );
  }

  @override
  Future<void> exportBackup(String path, String password) =>
      native.vaultExportBackup(token: _token, path: path, password: password);
  @override
  Future<int> restoreBackup(String path, String password) =>
      native.vaultRestoreBackup(token: _token, path: path, password: password);
  @override
  Future<List<CommandSnippet>> readSnippets() async =>
      (jsonDecode(await native.vaultRead(token: _token, kind: 'snippets'))
              as List)
          .map(
            (s) => CommandSnippet(
              s['id'] as String,
              s['name'] as String,
              s['command'] as String,
              tags: [
                for (final tag in (s['tags'] as List? ?? const []))
                  if (tag is String) tag,
              ],
            ),
          )
          .toList();
  @override
  Future<void> saveSnippet(
    String id,
    String name,
    String command, {
    List<String> tags = const [],
  }) => native.vaultSaveSnippet(
    token: _token,
    id: id,
    name: name,
    command: command,
    tags: tags,
  );
  @override
  Future<void> deleteSnippet(String id) =>
      native.vaultDeleteSnippet(token: _token, id: id);
  @override
  Future<void> lock() => native.vaultLock(token: _token);
}
