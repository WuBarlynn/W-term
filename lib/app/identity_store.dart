import 'host_store.dart';

class SavedIdentity {
  final String id, name, username, kind;
  const SavedIdentity({
    required this.id,
    required this.name,
    required this.username,
    required this.kind,
  });
}

class IdentityDraft {
  final String id, name, username, kind;
  final bool replaceSecret;
  String password, privateKey, passphrase;
  IdentityDraft({
    this.id = '',
    required this.name,
    required this.username,
    required this.kind,
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
    this.replaceSecret = true,
  });
  void clear() {
    password = '';
    privateKey = '';
    passphrase = '';
  }
}

abstract interface class IdentityStore {
  Future<List<SavedIdentity>> identities();
  Future<String> saveIdentity(IdentityDraft draft);
  Future<void> deleteIdentity(String id);
  Future<HostProfile> saveHost(HostProfile profile, IdentityDraft? draft);
  Future<String> authenticateIdentity(
    String identityId,
    String connectionId,
    String fingerprint,
  );
}

abstract interface class FolderTreeStore {
  Future<void> deleteFolder(String path, {bool deleteHosts = false});
}

abstract interface class VaultMaintenance {
  Future<void> changePassword(String current, String next);
  Future<void> exportBackup(String path, String password);
  Future<int> restoreBackup(String path, String password);
}
