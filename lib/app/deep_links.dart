import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'host_store.dart';

/// A deep link received before the workspace is ready; the workspace consumes
/// and clears it when mounted.
final pendingDeepLink = ValueNotifier<Uri?>(null);

/// Parses `wterm://connect?host=...&port=22&username=...&name=...`.
/// Credentials are deliberately not accepted in URLs.
HostProfile? hostProfileFromDeepLink(Uri uri) {
  if (uri.scheme.toLowerCase() != 'wterm') return null;
  if (uri.host.toLowerCase() != 'connect' && uri.path != '/connect') {
    return null;
  }
  final host = uri.queryParameters['host']?.trim() ?? '';
  if (host.isEmpty ||
      host.length > 255 ||
      RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(host)) {
    return null;
  }
  final portValue = int.tryParse(uri.queryParameters['port'] ?? '22');
  if (portValue == null || portValue < 1 || portValue > 65535) return null;
  final username = (uri.queryParameters['username'] ?? '').trim();
  if (username.length > 128 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(username)) {
    return null;
  }
  final name = (uri.queryParameters['name'] ?? '').trim();
  return HostProfile(
    id: HostProfile.newId(),
    name: name.isEmpty ? host : name.substring(0, name.length.clamp(0, 128)),
    host: host,
    port: portValue,
    username: username,
  );
}

class DeepLinkService {
  Future<void> start() async {
    if (!(kIsWeb ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.windows)) {
      return;
    }
    final links = AppLinks();
    try {
      _handle(await links.getInitialLink());
      links.uriLinkStream.listen(
        _handle,
        onError: (Object _) {
          // A malformed link must never interrupt the UI.
        },
      );
    } catch (_) {
      // Deep links are optional on platforms without URL registration.
    }
  }

  void _handle(Uri? uri) {
    if (uri != null && hostProfileFromDeepLink(uri) != null) {
      pendingDeepLink.value = uri;
    }
  }
}

final deepLinkService = DeepLinkService();
