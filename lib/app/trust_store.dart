import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class TrustStore {
  Future<Map<String, String>> read();
  Future<void> remember(String endpoint, String fingerprint);
  Future<void> forget(String endpoint);
}

String endpointKey(String host, int port) =>
    '${host.trim().toLowerCase()}:$port';

class KeychainTrustStore implements TrustStore {
  static const _key = 'wterm.known-hosts.v1';
  final FlutterSecureStorage storage;
  KeychainTrustStore({
    this.storage = const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
    ),
  });

  @override
  Future<Map<String, String>> read() async {
    final data = await storage.read(key: _key);
    if (data == null) return {};
    // Corrupt trust data must fail closed, not become an empty trust store.
    return Map<String, String>.from(jsonDecode(data) as Map);
  }

  @override
  Future<void> remember(String endpoint, String fingerprint) async {
    final entries = await read();
    final previous = entries[endpoint];
    if (previous != null && previous != fingerprint) {
      throw StateError('服务器指纹发生变化，已阻止覆盖');
    }
    entries[endpoint] = fingerprint;
    await storage.write(key: _key, value: jsonEncode(entries));
  }

  @override
  Future<void> forget(String endpoint) async {
    final entries = await read();
    entries.remove(endpoint);
    await storage.write(key: _key, value: jsonEncode(entries));
  }
}
