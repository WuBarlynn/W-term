import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'identity_store.dart';

/// Rotating local backups encrypted with a random key held by the system
/// keystore. The key never enters the backup directory or logs.
class AutoBackupService {
  static const _keyName = 'wterm.auto-backup.key.v1';
  static const _maxFiles = 5;
  static const _minimumInterval = Duration(hours: 24);

  final Future<Directory> Function() _directory;
  final FlutterSecureStorage storage;
  final Random _random;
  final Future<String?> Function()? keyReader;
  final Future<void> Function(String value)? keyWriter;

  AutoBackupService({
    Future<Directory> Function()? directory,
    this.storage = const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
    ),
    Random? random,
    this.keyReader,
    this.keyWriter,
  }) : _directory =
           directory ??
           (() async {
             final root = await getApplicationSupportDirectory();
             return Directory('${root.path}/backups');
           }),
       _random = random ?? Random.secure();

  Future<List<File>> list() async {
    try {
      final directory = await _directory();
      if (!await directory.exists()) return const [];
      final files = await directory
          .list()
          .where(
            (entity) => entity is File && entity.path.endsWith('.wterm-backup'),
          )
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  Future<String> _backupKey() async {
    final existing = await (keyReader != null
        ? keyReader!()
        : storage.read(key: _keyName));
    if (existing != null && existing.isNotEmpty) return existing;
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final key = base64Encode(bytes);
    if (keyWriter != null) {
      await keyWriter!(key);
    } else {
      await storage.write(key: _keyName, value: key);
    }
    return key;
  }

  Future<File?> ensureRecent(
    VaultMaintenance store, {
    bool force = false,
  }) async {
    try {
      final files = await list();
      if (!force && files.isNotEmpty) {
        final modified = await files.first.lastModified();
        if (DateTime.now().difference(modified) < _minimumInterval) {
          return null;
        }
      }
      final directory = await _directory();
      await directory.create(recursive: true);
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final name =
          'auto-${now.year}${two(now.month)}${two(now.day)}-'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}.wterm-backup';
      final file = File('${directory.path}/$name');
      await store.exportBackup(file.path, await _backupKey());
      await _prune(directory);
      return file;
    } catch (_) {
      // Automatic backup is best-effort and must never block the workspace.
      return null;
    }
  }

  Future<int> restore(File file, VaultMaintenance store) async {
    final key = await (keyReader != null
        ? keyReader!()
        : storage.read(key: _keyName));
    if (key == null || key.isEmpty) {
      throw StateError('本机自动备份密钥已丢失，无法恢复该备份');
    }
    return store.restoreBackup(file.path, key);
  }

  Future<void> _prune(Directory directory) async {
    final files = await list();
    for (var index = _maxFiles; index < files.length; index++) {
      try {
        await files[index].delete();
      } catch (_) {
        // A locked or already removed file can be retried next time.
      }
    }
  }
}

final autoBackup = AutoBackupService();
