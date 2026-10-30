import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class HostProfile {
  final String id, name, host, username, group, identityId;
  final int port;
  final List<String> tags;
  final bool favorite;
  final List<String> jumpHostIds;
  final String startupCommand;
  final List<String> environment;
  final String wiki;
  final String icon;
  HostProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.username,
    this.port = 22,
    this.group = '',
    this.identityId = '',
    List<String> tags = const [],
    this.favorite = false,
    List<String> jumpHostIds = const [],
    this.startupCommand = '',
    List<String> environment = const [],
    this.wiki = '',
    this.icon = '',
  }) : tags = List.unmodifiable(tags),
       jumpHostIds = List.unmodifiable(jumpHostIds),
       environment = List.unmodifiable(environment) {
    if ([id, name, host, username].any((s) => s.trim().isEmpty) ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('主机配置无效');
    }
    if (jumpHostIds.length > 4 ||
        jumpHostIds.any((id) => id.trim().isEmpty) ||
        jumpHostIds.toSet().length != jumpHostIds.length ||
        jumpHostIds.contains(id)) {
      throw const FormatException('跳板路线无效');
    }
  }
  static String newId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  factory HostProfile.fromJson(Map<String, dynamic> v) => HostProfile(
    id: v['id'] as String,
    name: v['name'] as String,
    host: v['host'] as String,
    username: v['username'] as String,
    port: v['port'] as int,
    group: v['group'] as String,
    tags: List<String>.from(v['tags'] as List),
    favorite: v['favorite'] as bool,
    identityId: v['identityId'] as String? ?? '',
    jumpHostIds: List<String>.from(v['jumpHostIds'] as List? ?? const []),
    startupCommand: v['startupCommand'] as String? ?? '',
    environment: List<String>.from(v['environment'] as List? ?? const []),
    wiki: v['wiki'] as String? ?? '',
    icon: v['icon'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'username': username,
    'port': port,
    'group': group,
    'tags': tags,
    'favorite': favorite,
    if (identityId.isNotEmpty) 'identityId': identityId,
    if (jumpHostIds.isNotEmpty) 'jumpHostIds': jumpHostIds,
    if (startupCommand.isNotEmpty) 'startupCommand': startupCommand,
    if (environment.isNotEmpty) 'environment': environment,
    if (wiki.isNotEmpty) 'wiki': wiki,
    if (icon.isNotEmpty) 'icon': icon,
  };
  HostProfile toggleFavorite() => HostProfile(
    id: id,
    name: name,
    host: host,
    username: username,
    port: port,
    group: group,
    tags: tags,
    favorite: !favorite,
    identityId: identityId,
    jumpHostIds: jumpHostIds,
    startupCommand: startupCommand,
    environment: environment,
    wiki: wiki,
    icon: icon,
  );
  HostProfile withWiki(String value) => HostProfile(
    id: id,
    name: name,
    host: host,
    username: username,
    port: port,
    group: group,
    tags: tags,
    favorite: favorite,
    identityId: identityId,
    jumpHostIds: jumpHostIds,
    startupCommand: startupCommand,
    environment: environment,
    wiki: value,
    icon: icon,
  );
  HostProfile withFavorite(bool value) => HostProfile(
    id: id,
    name: name,
    host: host,
    username: username,
    port: port,
    group: group,
    tags: tags,
    favorite: value,
    identityId: identityId,
    jumpHostIds: jumpHostIds,
    startupCommand: startupCommand,
    environment: environment,
    wiki: wiki,
    icon: icon,
  );
  bool matches(String query) => [
    name,
    host,
    username,
    group,
    ...tags,
  ].join(' ').toLowerCase().contains(query.trim().toLowerCase());
}

abstract interface class HostStore {
  Future<List<HostProfile>> read();
  Future<void> write(List<HostProfile> profiles);
}

/// Transitional device-local store. Credentials are deliberately absent from
/// the schema; the future vault migration must explicitly import this version.
abstract interface class FolderStore {
  Future<List<String>> readFolders();
  Future<void> writeFolders(List<String> folders);
}

class KeychainHostStore implements HostStore, FolderStore {
  final FlutterSecureStorage storage;
  static const key = 'wterm.host-profiles.v1';
  KeychainHostStore({
    this.storage = const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
    ),
  });
  @override
  Future<List<String>> readFolders() async {
    final raw = await storage.read(key: 'wterm.host-folders.v1');
    if (raw == null) return [];
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['version'] != 1) throw const FormatException('不支持的文件夹版本');
    final folders = List<String>.from(data['folders'] as List);
    if (folders.any((f) => f.trim().isEmpty) ||
        folders.toSet().length != folders.length) {
      throw const FormatException('文件夹配置无效');
    }
    return folders;
  }

  @override
  Future<void> writeFolders(List<String> folders) async {
    if (folders.any((f) => f.trim().isEmpty) ||
        folders.toSet().length != folders.length) {
      throw const FormatException('文件夹配置无效');
    }
    await storage.write(
      key: 'wterm.host-folders.v1',
      value: jsonEncode({'version': 1, 'folders': folders}),
    );
  }

  @override
  Future<List<HostProfile>> read() async {
    final raw = await storage.read(key: key);
    if (raw == null) return [];
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['version'] != 1) throw const FormatException('不支持的主机配置版本');
    final hosts = (data['hosts'] as List)
        .map((v) => HostProfile.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (hosts.map((h) => h.id).toSet().length != hosts.length) {
      throw const FormatException('主机 ID 重复');
    }
    return hosts;
  }

  @override
  Future<void> write(List<HostProfile> profiles) async {
    if (profiles.map((h) => h.id).toSet().length != profiles.length) {
      throw const FormatException('主机 ID 重复');
    }
    await storage.write(
      key: key,
      value: jsonEncode({
        'version': 1,
        'hosts': profiles.map((h) => h.toJson()).toList(),
      }),
    );
  }
}
