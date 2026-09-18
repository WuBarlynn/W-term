# Local vault — schema 2

The application starts with master-password creation/unlock. Host profiles, folder paths, reusable identities and credential secrets are stored in `wterm-vault.db` under the platform application-support directory. By default the master password is not persisted. Opting into quick unlock stores it in a device-only Keychain item gated by the currently enrolled biometric set.

## Encryption and schema

Rust `rusqlite` builds SQLCipher 4.10.0 through `libsqlite3-sys` 0.36.0. Apple builds use CommonCrypto. The app checks `cipher_version` and uses compatibility mode 4, memory-only temporary SQLite storage, SQLCipher memory security, DELETE journals and FULL synchronous mode. Master passwords are passed using `sqlite3_key` / `sqlite3_rekey`, not SQL string interpolation. See the [SQLCipher API](https://www.zetetic.net/sqlcipher/sqlcipher-api/).

Schema 2 has encrypted host/folder records, metadata, and an `identities` table. Each identity contains a display name, username, authentication type and either a password or private-key material plus its optional passphrase. A host carries only an `identityId` reference. Unexpected secret fields in host JSON are rejected. Private keys are parsed and their passphrases verified before saving. Creating a host with a new identity is a single transaction. Updating an identity's username also updates referencing host metadata. Deleting an identity still referenced by hosts is blocked.

The Flutter identity list receives only ID/name/username/type. Stored secrets are not read back into the editor: edits retain the existing secret unless replacement is explicitly selected. On connection, Rust retrieves the saved credential and uses it on the already verified SSH transport. Initial private-key import and typed passwords necessarily pass through Dart/FFI. Rust uses zeroizing buffers and sensitive-input guards where owned; Dart strings and intermediate copies cannot guarantee erasure. No credential logging or plaintext credential export is enabled.

## Upgrade and migration

Authenticated opening upgrades schema 1 to schema 2 transactionally and preserves existing profiles. Older application versions reject schema 2 rather than modifying it. The format marker remains `wterm-vault-v1`; the SQL `user_version` distinguishes schema revisions.

Legacy Keychain host/folder records import once in a transaction. They remain as an OS-protected fallback copy; subsequent edits update only SQLCipher. The old application did not save passwords or private keys, so those cannot be recovered by migration: existing hosts need credentials attached once. The verified-server fingerprint store remains independent in Keychain, including after backup restore.

## Locking and connection

The unlocked database is accessed by a random session token. Dropping the handle locks the vault; stale tokens cannot read/write or close a newly unlocked session. Manual lock removes the workspace and disconnects SSH sessions. iOS backgrounding retains the in-process vault session, including a successful unlock finishing behind the privacy shield. Returning to the app does not require authentication again. Process termination (including an OS kill) loses the session; launching again requires password or biometric unlock. A Flutter privacy cover sits above navigation while inactive. Real-device app-switcher timing remains unverified; macOS system-lock/inactivity integration is not implemented.

Double-click a host to connect; a single click does nothing. The host menu's Edit action opens the separate profile editor. A first-time or changed server fingerprint still requires the existing verification/blocking flow. There is no automatic command replay.

## Master password and encrypted backups

**保险库与备份** in the sidebar supports:

- Master-password change after validating the current password; SQLCipher re-encrypts the database. Existing backup passwords do not change.
- Export to a new encrypted database using an independent backup password of at least 12 characters. The schema and encrypted identity secrets are included. The `sqlcipher_export` target receives a bound key and an explicit schema version. Only an encrypted temporary file is handed to the native save/share flow.
- Restore from a read-only encrypted source (up to 512 MiB). Invalid passwords/formats fail before destination changes. Hosts and identities receive new IDs and a ` (恢复)` suffix, and identity references are remapped in a transaction. Existing records are retained. Folder paths merge by name. Repeated restores intentionally create additional copies.

There is no recovery code or passwordless reset. If the main password is lost, an independently password-protected backup can be restored into a new unlocked vault, such as on another installation. Losing both passwords cannot recover the contents. Backup/save/share UI and interruption behavior still need real-device testing.

## Folder semantics

Folder paths use `/` between levels. New subfolders appear beneath their parent; ancestors are derived for existing grouped hosts. Deleting a folder removes its subtree and either moves all contained hosts to Uncategorized or deletes them, in one transaction. Reusable identity secrets are retained in both modes. Folder rename/drag-to-move is not implemented; host editing can change its folder path.

## Tests and remaining scope

Rust tests cover ciphertext inspection, wrong-password nonmutation, schema-1 upgrade, transaction rollback, stale tokens, reference validation, credential persistence, recursive folder deletion, master-password rotation, and backup restore without overwriting current data. An isolated AsyncSSH test authenticates with both a saved password and saved encrypted private key. The native Dart bridge smoke test exercises the same storage and maintenance APIs through generated bindings.

Quick unlock builds on macOS and the iOS simulator; mocked UI flows pass. System biometric/Keychain behavior still requires real-device verification. Still pending: recovery codes, generated keys and standalone encrypted key export, GitHub synchronization, real Keychain/device integration and full lifecycle/security review. This remains a development preview.

## Biometric quick unlock — compiled, device validation pending

The unlock screen offers an explicit enrollment checkbox when LocalAuthentication reports usable Touch ID or Face ID. Enrollment occurs only after opening the vault with its master password. `flutter_secure_storage` uses a separate service `dev.wterm.biometric-vault`, `biometryCurrentSet`, device-only unlocked accessibility, and no iCloud synchronization. macOS uses the Data Protection Keychain; it never substitutes an unprotected login-keychain item. The application-support marker contains only the enabled preference, never a secret; reading the credential itself invokes system Keychain authentication. Cancellation or invalidated enrollment leaves the password route available.

The Settings dialog can delete enrollment. Password rotation invalidates enrollment before rekeying, so a crash cannot leave an old credential enabled against the new vault password. A rejected password change can also disable enrollment; re-enable it on the unlock screen after a successful manual unlock. The password is held transiently in Dart during open/enrollment; clearing references does not guarantee zeroization of Dart strings.

`NSFaceIDUsageDescription` is declared for iOS. Signed-device Keychain access, biometric enrollment changes, cancellation, lockout, and process restart require later manual validation. The subsequent iteration completed macOS/iOS simulator builds, 35 Flutter tests and the native vault bridge smoke test. Mocked authentication tests do not certify device Keychain access.
