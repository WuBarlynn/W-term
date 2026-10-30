import '../src/rust/api/client.dart';
import '../src/rust/api/proxy.dart';

abstract interface class ConnectionProxyStore {
  Future<ProxySettings> proxySettings();
  Future<void> saveProxySettings(ProxySettings settings, String password);
  Future<List<ProxyProfile>> proxyProfiles();
  Future<String> saveProxyProfile(ProxyProfileInput profile, String password);
  Future<void> deleteProxyProfile(String id);
  Future<String> hostProxyBinding(String hostId);
  Future<void> setHostProxyBinding(String hostId, String binding);
  Future<ProxyTestResult> testProxyGlobal(String targetHost, int targetPort);
  Future<ProxyTestResult> testProxyProfile(
    String id,
    String targetHost,
    int targetPort,
  );
  Future<ProxyTestResult> testProxyDraft(
    ProxyDraft draft,
    String password,
    String targetHost,
    int targetPort,
  );
  Future<ServerIdentity> probeWithProxy(
    String host,
    int port, {
    String operationId = '',
  });
  Future<ServerIdentity> probeWithHostProxy(
    String hostId,
    String host,
    int port, {
    String operationId = '',
  });
  Future<ServerIdentity> probeThrough(
    String parentConnectionId,
    String host,
    int port, {
    String operationId = '',
  });
  Future<void> cancelProbe(String operationId);
}
