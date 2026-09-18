import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../src/rust/api/vault.dart' as native;
import 'host_store.dart';
import 'quick_unlock.dart';
import 'identity_store.dart';

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
    implements VaultSession, IdentityStore, FolderTreeStore, VaultMaintenance {
  final String _token;
  final QuickUnlock _quick;
  @override
  final bool legacyImported;
  NativeVaultSession(
    this._token,
    this.legacyImported, {
    QuickUnlock? quickUnlock,
  }) : _quick = quickUnlock ?? QuickUnlock();
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
  Future<void> lock() => native.vaultLock(token: _token);
}
