import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/connection_route.dart';
import 'package:wterm/app/host_store.dart';
import 'package:wterm/app/identity_store.dart';
import 'package:wterm/app/proxy_store.dart';
import 'package:wterm/features/host_editor.dart';
import 'package:wterm/src/rust/api/proxy.dart' show ProxyProfile;

HostProfile profile(
  String id,
  String host, {
  List<String> jumps = const [],
  String identity = '',
}) => HostProfile(
  id: id,
  name: id,
  host: host,
  username: 'tester',
  identityId: identity,
  jumpHostIds: jumps,
);

class Library implements IdentityStore {
  @override
  Future<List<SavedIdentity>> identities() async => [
    const SavedIdentity(
      id: 'login',
      name: 'Login',
      username: 'tester',
      kind: 'password',
    ),
  ];
  @override
  Future<String> saveIdentity(IdentityDraft draft) async => 'login';
  @override
  Future<void> deleteIdentity(String id) async {}
  @override
  Future<HostProfile> saveHost(HostProfile host, IdentityDraft? draft) async =>
      host;
  @override
  Future<String> authenticateIdentity(
    String identityId,
    String connectionId,
    String fingerprint,
  ) async => 'tester';
  @override
  Future<String> authenticateJumpIdentity(
    String identityId,
    String connectionId,
    String fingerprint,
  ) async => 'tester';
}

class ProxyLibrary extends Library implements ConnectionProxyStore {
  String binding = '';
  final profiles = const [
    ProxyProfile(
      id: 'corp',
      name: 'Corp',
      mode: 'http',
      host: 'proxy.example',
      port: 3128,
      authenticate: false,
      username: '',
      passwordSaved: false,
    ),
  ];
  @override
  Future<List<ProxyProfile>> proxyProfiles() async => profiles;
  @override
  Future<String> hostProxyBinding(String hostId) async => binding;
  @override
  Future<void> setHostProxyBinding(String hostId, String value) async {
    binding = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'host profile round-trips jump references and rejects invalid routes',
    () {
      final target = profile('target', 'target.example', jumps: ['jump']);
      expect(target.toJson()['jumpHostIds'], ['jump']);
      expect(HostProfile.fromJson(target.toJson()).jumpHostIds, ['jump']);
      expect(
        profile('plain', 'plain.example').toJson().containsKey('jumpHostIds'),
        isFalse,
      );
      expect(
        HostProfile.fromJson({...profile('legacy', 'legacy.example').toJson()})
            .jumpHostIds,
        isEmpty,
      );
      expect(
        () => profile('self', 'self.example', jumps: ['self']),
        throwsFormatException,
      );
      expect(
        () => profile('dup', 'dup.example', jumps: ['a', 'a']),
        throwsFormatException,
      );
      expect(
        () => profile('many', 'many.example', jumps: ['1', '2', '3', '4', '5']),
        throwsFormatException,
      );
    },
  );

  test('route expansion keeps order and scopes trust keys to the path', () {
    final jumpA = profile('jump-a', '10.0.0.1');
    final jumpB = profile('jump-b', '10.0.0.2', jumps: ['jump-a']);
    final target = profile('target', '10.0.0.9', jumps: ['jump-b']);
    final route = buildRoute(target, {
      'jump-a': jumpA,
      'jump-b': jumpB,
      'target': target,
    });
    expect(route.map((hop) => hop.host.id), ['jump-a', 'jump-b', 'target']);
    expect(route[0].trustKey, '10.0.0.1:22');
    expect(route[1].trustKey, '10.0.0.1:22 > 10.0.0.2:22');
    expect(route[2].trustKey, '10.0.0.1:22 > 10.0.0.2:22 > 10.0.0.9:22');
    expect(route[2].via, ['10.0.0.1:22', '10.0.0.2:22']);
    expect(route[2].isJump, isTrue);
    final direct = profile('direct', 'direct.example');
    expect(
      buildRoute(direct, {'direct': direct}).single.trustKey,
      'direct.example:22',
    );
  });

  test('route expansion rejects missing, cyclic, duplicate and deep paths', () {
    final missing = profile('target', 'target.example', jumps: ['gone']);
    expect(
      () => buildRoute(missing, {'target': missing}),
      throwsA(isA<RouteException>()),
    );
    final a = profile('a', 'a.example', jumps: ['b']);
    final b = profile('b', 'b.example', jumps: ['a']);
    expect(
      () => buildRoute(a, {'a': a, 'b': b}),
      throwsA(isA<RouteException>()),
    );
    final shared = profile('s', 's.example', jumps: ['c']);
    final c = profile('c', 'c.example');
    final target = profile('t', 't.example', jumps: ['s', 'c']);
    expect(
      () => buildRoute(target, {'s': shared, 'c': c, 't': target}),
      throwsA(isA<RouteException>()),
    );
    final chain = <String, HostProfile>{};
    for (var i = 0; i < 6; i++) {
      final id = 'h$i';
      chain[id] = profile(
        id,
        '$id.example',
        jumps: i == 0 ? const [] : ['h${i - 1}'],
      );
    }
    expect(
      () => buildRoute(chain['h5']!, chain),
      throwsA(isA<RouteException>()),
    );
  });

  testWidgets('host editor adds ordered jump hosts', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final target = profile('target', 'target.example', identity: 'login');
    final jumpA = profile('jump-a', 'jump-a.example', identity: 'login');
    final jumpB = profile('jump-b', 'jump-b.example', identity: 'login');
    HostProfile? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showDialog<HostProfile>(
                  context: context,
                  builder: (_) => HostEditor(
                    profile: target,
                    credentials: Library(),
                    candidates: [target, jumpA, jumpB],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('跳板路线'), findsOneWidget);
    for (final id in ['jump-a', 'jump-b']) {
      await tester.ensureVisible(find.text('添加跳板'));
      await tester.tap(find.text('添加跳板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(id).last);
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved?.jumpHostIds, ['jump-a', 'jump-b']);
  });

  testWidgets('host editor persists an explicit direct proxy binding', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = ProxyLibrary();
    final target = profile('target', 'target.example', identity: 'login');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<HostProfile>(
                context: context,
                builder: (_) => HostEditor(
                  profile: target,
                  credentials: store,
                  proxies: store,
                  proxyProfiles: store.profiles,
                  proxyBinding: '',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('连接代理（仅第一跳）'), findsOneWidget);
    await tester.ensureVisible(find.text('继承默认代理'));
    await tester.tap(find.text('继承默认代理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直连（不使用代理）').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.binding, 'direct');
  });
}
