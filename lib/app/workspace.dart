import 'interactive_auth.dart';
import 'connection_route.dart';
import 'forward_store.dart';
import 'terminal_session.dart';
import 'command_history.dart';
import 'update_checker.dart';
import 'workspace_layout.dart';
import 'proxy_store.dart';
import '../features/proxy_dialog.dart';
import '../features/auth_challenge_dialog.dart';
import '../features/forwarding_dialog.dart';
import 'errors.dart';
import 'app_version_label.dart';
import 'host_store.dart';
import 'identity_store.dart';
import 'snippet_store.dart';
import 'sync_store.dart';
import '../features/sync_dialog.dart';
import '../features/snippets_dialog.dart';
import '../features/command_history_dialog.dart';
import '../features/host_editor.dart';
import '../features/identities_pane.dart';
import '../features/vault_settings.dart';
import '../features/hosts_page.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';

import '../features/connect_dialog.dart';
import '../features/files_pane.dart';
import '../features/terminal_pane.dart';
import '../src/rust/api/client.dart' as native;
import '../src/rust/api/proxy.dart' show ProxyProfile;
import 'trust_store.dart';

class Workspace extends StatefulWidget {
  final TrustStore? trustStore;
  final HostStore? hostStore;
  final VoidCallback? onLock;
  const Workspace({super.key, this.trustStore, this.hostStore, this.onLock});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _Session {
  final String id, host, username, hostId;
  final TerminalSession terminal;
  final HostProfile? profile;
  _Session(
    this.id,
    this.host,
    this.username,
    this.hostId,
    this.terminal, {
    this.profile,
  });
  bool get connected => !terminal.ended;
}

class _RouteHop {
  final String name, host, username, identityId, trustKey, hostId;
  final int port;
  final List<String> via;
  const _RouteHop({
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.identityId,
    required this.trustKey,
    required this.via,
    required this.hostId,
  });
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  late final TrustStore trust = widget.trustStore ?? KeychainTrustStore();
  late final HostStore hostStore = widget.hostStore ?? KeychainHostStore();
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final hostPanelKey = GlobalKey<HostsPageState>();
  bool showIdentities = false, sidebarCollapsed = false;
  double sidebarWidth = 272;
  int identitiesEpoch = 0;
  final sessions = <_Session>[];
  final commandHistory = CommandHistory();
  final tabs = <WorkspaceTab>[];
  int selected = -1, attempt = 0;
  BroadcastScope broadcastScope = BroadcastScope.off;
  bool connecting = false, preparing = false;
  Timer? _layoutSaveTimer, _updateTimer;
  bool _restoredLayout = false;
  String status = '';
  String? pending;
  String? activeOperationId, connectionRootId;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(commandHistory.load());
    unawaited(_restoreLayout());
    _updateTimer = Timer(const Duration(seconds: 6), _autoCheckUpdates);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _layoutSaveTimer?.cancel();
    _updateTimer?.cancel();
    unawaited(_saveLayout());
    attempt++;
    final operation = activeOperationId;
    if (operation != null && hostStore is ConnectionProxyStore) {
      unawaited(
        (hostStore as ConnectionProxyStore)
            .cancelProbe(operation)
            .catchError((Object _) {}),
      );
    }
    activeOperationId = null;
    final root = connectionRootId;
    connectionRootId = null;
    if (root != null) {
      unawaited(
        native.disconnect(connectionId: root).catchError((Object _) {}),
      );
    }
    if (pending != null && pending != root) {
      unawaited(
        native.disconnect(connectionId: pending!).catchError((Object _) {}),
      );
    }
    for (final s in sessions) {
      unawaited(s.terminal.close());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && Platform.isIOS) {
      cancelConnect();
      // Preview policy: close on background; do not promise an alive socket.
      for (final session in sessions) {
        unawaited(session.terminal.close());
      }
      if (mounted) setState(() {});
    }
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
      );
    }
  }

  void cancelConnect() {
    attempt++;
    final operation = activeOperationId;
    activeOperationId = null;
    if (operation != null && hostStore is ConnectionProxyStore) {
      unawaited(
        (hostStore as ConnectionProxyStore)
            .cancelProbe(operation)
            .catchError((Object _) {}),
      );
    }
    final root = connectionRootId;
    connectionRootId = null;
    if (root != null) {
      unawaited(
        native.disconnect(connectionId: root).catchError((Object _) {}),
      );
    }
    final id = pending;
    pending = null;
    if (id != null && id != root) {
      unawaited(native.disconnect(connectionId: id).catchError((Object _) {}));
    }
    if (mounted) {
      setState(() {
        connecting = false;
        preparing = false;
        status = '';
      });
    }
  }

  Future<(ConnectionRequest, String)?> prepareConnection(
    HostProfile? profile,
  ) async {
    final credentials = hostStore is IdentityStore
        ? hostStore as IdentityStore
        : null;
    if (profile != null && profile.identityId.isEmpty && credentials != null) {
      var candidates = const <HostProfile>[];
      try {
        candidates = await hostStore.read();
      } catch (_) {}
      final proxyStore = hostStore is ConnectionProxyStore
          ? hostStore as ConnectionProxyStore
          : null;
      var proxyProfiles = const <ProxyProfile>[];
      var proxyBinding = '';
      if (proxyStore != null) {
        try {
          proxyProfiles = await proxyStore.proxyProfiles();
          proxyBinding = await proxyStore.hostProxyBinding(profile.id);
        } catch (e) {
          // Do not open the editor without the current binding: saving would
          // silently reset a named proxy to inherit.
          throw StateError('无法读取代理设置：${userFacingError(e)}');
        }
      }
      if (!mounted) return null;
      profile = await showDialog<HostProfile>(
        context: context,
        barrierDismissible: false,
        builder: (_) => HostEditor(
          profile: profile,
          credentials: credentials,
          candidates: candidates,
          proxies: proxyStore,
          proxyProfiles: proxyProfiles,
          proxyBinding: proxyBinding,
        ),
      );
      if (profile == null || !mounted) return null;
      await hostPanelKey.currentState?.load();
    }
    if (profile != null &&
        profile.identityId.isNotEmpty &&
        credentials != null) {
      return (
        ConnectionRequest(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          password: '',
          privateKey: '',
          passphrase: '',
        ),
        profile.identityId,
      );
    }
    if (!mounted) return null;
    final request = await showDialog<ConnectionRequest>(
      context: context,
      builder: (_) => ConnectDialog(
        profile: profile,
        persistCredentials: credentials != null,
      ),
    );
    if (request == null) return null;
    if (!mounted) {
      request.clearSecrets();
      return null;
    }
    try {
      if (credentials != null &&
          (request.password.isNotEmpty || request.privateKey.isNotEmpty)) {
        final host = HostProfile(
          id: profile?.id ?? HostProfile.newId(),
          name: profile?.name ?? request.host,
          host: request.host,
          port: request.port,
          username: request.username,
          group: profile?.group ?? '',
          tags: profile?.tags ?? [],
          favorite: profile?.favorite ?? false,
          jumpHostIds: profile?.jumpHostIds ?? const [],
          startupCommand: profile?.startupCommand ?? '',
          environment: profile?.environment ?? const [],
          wiki: profile?.wiki ?? '',
          icon: profile?.icon ?? '',
        );
        final saved = await credentials.saveHost(
          host,
          IdentityDraft(
            name: '${host.name} · ${request.username}',
            username: request.username,
            kind: request.privateKey.isEmpty ? 'password' : 'key',
            password: request.password,
            privateKey: request.privateKey,
            passphrase: request.passphrase,
          ),
        );
        request.clearSecrets();
        await hostPanelKey.currentState?.load();
        return (request, saved.identityId);
      }
      return (request, '');
    } catch (_) {
      request.clearSecrets();
      rethrow;
    }
  }

  Future<void> connect([HostProfile? profile, _Session? replace]) async {
    if (connecting) return;
    final currentAttempt = ++attempt;
    bool active() => mounted && currentAttempt == attempt;
    final operationId = HostProfile.newId();
    activeOperationId = operationId;
    connectionRootId = null;
    setState(() {
      connecting = true;
      preparing = true;
      status = '准备连接…';
    });
    String? rootId, currentId, finalId;
    ConnectionRequest? cleanup;
    bool handedOff = false;
    try {
      final prepared = await prepareConnection(profile);
      if (prepared == null) return;
      final (request, savedIdentityId) = prepared;
      cleanup = request;
      if (!active()) return;
      final store = hostStore is ConnectionProxyStore
          ? hostStore as ConnectionProxyStore
          : null;
      final hops = <_RouteHop>[];
      if (profile == null) {
        hops.add(
          _RouteHop(
            name: request.host,
            host: request.host,
            port: request.port,
            username: request.username,
            identityId: '',
            trustKey: endpointKey(request.host, request.port),
            via: const [],
            hostId: '',
          ),
        );
      } else {
        final allHosts = await hostStore.read();
        if (!active()) return;
        final target =
            allHosts.where((h) => h.id == profile.id).firstOrNull ?? profile;
        final route = buildRoute(target, {for (final h in allHosts) h.id: h});
        for (final hop in route) {
          hops.add(
            _RouteHop(
              name: hop.host.name,
              host: hop.host.host,
              port: hop.host.port,
              username: hop.host.username,
              identityId: hop.host.identityId,
              trustKey: hop.trustKey,
              via: hop.via,
              hostId: hop.host.id,
            ),
          );
        }
        if (hops.length > 1 && store == null) {
          throw const RouteException('当前存储不支持跳板连接');
        }
        // The user may edit the address in the connection dialog.
        final target0 = hops.removeLast();
        hops.add(
          _RouteHop(
            name: target0.name,
            host: request.host,
            port: request.port,
            username: request.username,
            identityId: target0.identityId,
            trustKey: [
              ...target0.via,
              endpointKey(request.host, request.port),
            ].join(' > '),
            via: target0.via,
            hostId: target0.hostId,
          ),
        );
      }
      for (var index = 0; index < hops.length - 1; index++) {
        if (hops[index].identityId.isEmpty) {
          throw RouteException('跳板主机「${hops[index].name}」还没有保存身份，请先编辑该主机');
        }
      }
      setState(() => preparing = false);
      String? parent;
      var connectedUsername = '';
      for (var index = 0; index < hops.length; index++) {
        final hop = hops[index];
        final isTarget = index == hops.length - 1;
        if (!active()) return;
        setState(() {
          status = hops.length == 1
              ? '正在与 ${hop.host}:${hop.port} 建立连接…'
              : '第 ${index + 1}/${hops.length} 跳：正在连接 ${hop.host}:${hop.port}…';
        });
        final identity = index == 0
            ? (store != null
                  ? await store.probeWithHostProxy(
                      hop.hostId,
                      hop.host,
                      hop.port,
                      operationId: operationId,
                    )
                  : await native.probeServer(host: hop.host, port: hop.port))
            : await store!.probeThrough(
                parent!,
                hop.host,
                hop.port,
                operationId: operationId,
              );
        currentId = identity.connectionId;
        pending = currentId;
        if (index == 0) {
          rootId = currentId;
          connectionRootId = rootId;
        }
        if (!mounted || !active()) return;
        final known = (await trust.read())[hop.trustKey];
        if (!mounted || !active()) return;
        if (known != null && known != identity.fingerprint) {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('服务器指纹发生变化'),
              content: SelectableText(
                '${hops.length == 1 ? '' : '第 ${index + 1}/${hops.length} 跳：'}\n'
                '已阻止认证，未发送密码或私钥签名。\n请先向服务器管理员核实。\n\n'
                '信任上下文\n${hop.trustKey}\n\n原指纹\n$known\n\n当前指纹\n${identity.fingerprint}',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回'),
                ),
              ],
            ),
          );
          return;
        }
        if (known == null) {
          final allow = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: Text(
                hops.length == 1
                    ? '验证服务器身份'
                    : '验证第 ${index + 1}/${hops.length} 跳服务器',
              ),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hops.length == 1
                          ? '首次连接 ${hop.trustKey}，请通过可信渠道核对 SHA256 指纹。'
                          : '经 ${hop.via.join(' → ')} 连接 ${hop.host}:${hop.port}。请逐跳核对 SHA256 指纹。',
                    ),
                    const SizedBox(height: 20),
                    SelectableText(
                      identity.fingerprint,
                      style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '确认后，指纹将保存在此设备的钥匙串中，仅用于这条路线。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('信任并继续'),
                ),
              ],
            ),
          );
          if (allow != true || !active()) return;
          await trust.remember(hop.trustKey, identity.fingerprint);
        }
        if (!mounted || !active()) return;
        setState(() {
          status = hops.length == 1
              ? '正在认证 ${hop.username}@${hop.host}…'
              : '第 ${index + 1}/${hops.length} 跳：正在认证 ${hop.username}@${hop.host}…';
        });
        final username = await runInteractiveAuthentication(
          authenticate: () async {
            if (!isTarget) {
              final credentials = hostStore is IdentityStore
                  ? hostStore as IdentityStore
                  : null;
              if (credentials == null) {
                throw const RouteException('跳板认证需要保险库身份');
              }
              return credentials.authenticateJumpIdentity(
                hop.identityId,
                currentId!,
                identity.fingerprint,
              );
            }
            if (savedIdentityId.isNotEmpty && hostStore is IdentityStore) {
              return (hostStore as IdentityStore).authenticateIdentity(
                savedIdentityId,
                currentId!,
                identity.fingerprint,
              );
            }
            final authentication = native.authenticate(
              connectionId: currentId!,
              approvedFingerprint: identity.fingerprint,
              username: request.username,
              password: request.password,
              privateKey: request.privateKey,
              passphrase: request.passphrase,
            );
            request.clearSecrets();
            await authentication;
            return request.username;
          },
          poll: () => native.authChallenge(connectionId: currentId!),
          reply: (challengeId, answers) => native.answerAuthChallenge(
            connectionId: currentId!,
            challengeId: challengeId,
            answers: answers,
          ),
          cancel: () => native.disconnect(connectionId: currentId!),
          ask: (challenge, finished) async {
            if (!active()) return null;
            return showDialog<List<String>>(
              context: context,
              barrierDismissible: false,
              builder: (_) => AuthChallengeDialog(
                challenge: challenge,
                endpoint: hops.length == 1
                    ? '${hop.username}@${hop.host}'
                    : '第 ${index + 1}/${hops.length} 跳 · ${hop.username}@${hop.host}',
                finished: finished,
              ),
            );
          },
        );
        if (!mounted || !active()) return;
        if (!isTarget) {
          parent = currentId;
          pending = null;
          continue;
        }
        connectedUsername = username;
        finalId = currentId;
      }
      if (!mounted || !active() || finalId == null) return;
      final connectedId = finalId;
      final terminal = TerminalSession(
        connectionId: connectedId,
        host: hops.last.host,
        username: connectedUsername,
        onEnded: () => _terminalEnded(connectedId),
        onCommand: (command) => unawaited(
          commandHistory.record(
            command: command,
            host: hops.last.host,
            username: connectedUsername,
          ),
        ),
      );
      final session = _Session(
        connectedId,
        hops.last.host,
        connectedUsername,
        hops.last.hostId,
        terminal,
        profile: profile,
      );
      final replacedTab = replace == null ? null : _tabForSession(replace.id);
      setState(() {
        if (replace != null && replacedTab != null) {
          sessions.remove(replace);
          sessions.add(session);
          replacedTab.root = replaceSession(
            replacedTab.root,
            replace.id,
            session.id,
          );
          if (replacedTab.activeSessionId == replace.id) {
            replacedTab.activeSessionId = session.id;
          }
          selected = tabs.indexOf(replacedTab);
        } else {
          sessions.add(session);
          tabs.add(
            WorkspaceTab(
              id: HostProfile.newId(),
              root: SessionPane(session.id),
              activeSessionId: session.id,
            ),
          );
          selected = tabs.length - 1;
        }
      });
      if (replace != null && replacedTab != null) {
        await replace.terminal.close();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => replace.terminal.dispose(),
        );
      }
      if (profile != null) _applyStartup(session, profile);
      _scheduleLayoutSave();
      handedOff = true;
      activeOperationId = null;
      connectionRootId = null;
      pending = null;
    } catch (e) {
      if (active()) message('连接失败：${userFacingError(e)}');
    } finally {
      cleanup?.clearSecrets();
      pending = null;
      activeOperationId = null;
      if (!handedOff) {
        final cleanupId = rootId ?? currentId;
        if (cleanupId != null) {
          await native
              .disconnect(connectionId: cleanupId)
              .catchError((Object _) {});
        }
        connectionRootId = null;
      }
      if (active()) {
        setState(() {
          connecting = false;
          preparing = false;
          status = '';
        });
      }
    }
  }

  _Session? _sessionById(String id) =>
      sessions.where((session) => session.id == id).firstOrNull;

  WorkspaceTab? _tabForSession(String sessionId) =>
      tabs.where((tab) => containsSession(tab.root, sessionId)).firstOrNull;

  String _tabTitle(WorkspaceTab tab) {
    final custom = tab.customName?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    final active =
        _sessionById(tab.activeSessionId) ??
        _sessionById(firstSession(tab.root) ?? '');
    return active?.host ?? '会话';
  }

  void _terminalEnded(String id) {
    if (mounted) setState(() {});
  }

  int get _activeTabIndex =>
      selected >= 0 && selected < tabs.length ? selected : -1;

  void _reorderTab(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tabs.length) return;
    if (newIndex < 0 || newIndex >= tabs.length) return;
    final activeId = _activeTabIndex >= 0 ? tabs[selected].id : null;
    setState(() {
      final tab = tabs.removeAt(oldIndex);
      tabs.insert(newIndex, tab);
      final index = activeId == null
          ? -1
          : tabs.indexWhere((item) => item.id == activeId);
      selected = index >= 0 ? index : newIndex.clamp(0, tabs.length - 1);
    });
    _scheduleLayoutSave();
  }

  Future<void> closeTab(WorkspaceTab tab) async {
    if (!tabs.contains(tab)) return;
    final ids = sessionIds(tab.root);
    final doomed = ids.map(_sessionById).whereType<_Session>().toList();
    final connected = doomed.where((session) => session.connected).length;
    if (connected > 0) {
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('断开此标签中的 $connected 个会话？'),
          content: Text(
            '将断开以下会话：\n\n'
            '${doomed.map((s) => '· ${s.username}@${s.host}').join('\n')}\n\n'
            '当前窗格、文件传输和转发将结束。需要保留远端工作时，请先使用 tmux。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('断开'),
            ),
          ],
        ),
      );
      if (close != true) return;
    }
    if (!mounted) return;
    final activeId = _activeTabIndex >= 0 ? tabs[selected].id : null;
    // Remove the views and tab first: closing one tab must never rebuild or
    // dispose another tab's terminal session.
    setState(() {
      tabs.remove(tab);
      sessions.removeWhere((session) => ids.contains(session.id));
      final index = activeId == null
          ? -1
          : tabs.indexWhere((item) => item.id == activeId);
      selected = tabs.isEmpty
          ? -1
          : index >= 0
          ? index
          : tabs.length - 1;
    });
    _scheduleLayoutSave();
    await _disposeSessions(doomed);
  }

  Future<void> _closePane(String sessionId) async {
    final tab = _tabForSession(sessionId);
    if (tab == null) return;
    final ids = sessionIds(tab.root);
    if (ids.length <= 1) {
      await closeTab(tab);
      return;
    }
    final session = _sessionById(sessionId);
    if (session?.connected == true) {
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('关闭此窗格？'),
          content: const Text('此窗格的 SSH 会话将断开，其他窗格保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('关闭并断开'),
            ),
          ],
        ),
      );
      if (close != true) return;
    }
    if (!mounted) return;
    final activeId = _activeTabIndex >= 0 ? tabs[selected].id : null;
    setState(() {
      if (session != null) {
        sessions.remove(session);
      }
      final remaining = removeSession(tab.root, sessionId);
      if (remaining == null) {
        tabs.remove(tab);
      } else {
        tab.root = remaining;
        if (tab.activeSessionId == sessionId) {
          tab.activeSessionId = firstSession(remaining)!;
        }
      }
      final index = activeId == null
          ? -1
          : tabs.indexWhere((item) => item.id == activeId);
      selected = tabs.isEmpty
          ? -1
          : index >= 0
          ? index
          : tabs.length - 1;
    });
    _scheduleLayoutSave();
    if (session != null) {
      await session.terminal.close();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => session.terminal.dispose(),
      );
    }
  }

  void _splitBack(String sessionId) {
    final tab = _tabForSession(sessionId);
    if (tab == null || sessionIds(tab.root).length <= 1) return;
    final remaining = removeSession(tab.root, sessionId);
    if (remaining == null) return;
    setState(() {
      tab.root = remaining;
      if (tab.activeSessionId == sessionId) {
        tab.activeSessionId = firstSession(remaining)!;
      }
      tabs.add(
        WorkspaceTab(
          id: HostProfile.newId(),
          root: SessionPane(sessionId),
          activeSessionId: sessionId,
        ),
      );
      selected = tabs.length - 1;
    });
    _scheduleLayoutSave();
  }

  void _moveSessionToSplit(
    String sessionId,
    String targetSessionId,
    SplitEdge edge,
  ) {
    final source = _tabForSession(sessionId);
    final target = _tabForSession(targetSessionId);
    if (source == null || target == null || source.id == target.id) return;
    if (!containsSession(target.root, targetSessionId)) return;
    final activeId = _activeTabIndex >= 0 ? tabs[selected].id : null;
    setState(() {
      target.root = splitAt(
        target.root,
        targetSessionId,
        edge,
        SessionPane(sessionId),
      );
      target.activeSessionId = sessionId;
      final remaining = removeSession(source.root, sessionId);
      if (remaining == null) {
        tabs.remove(source);
      } else {
        source.root = remaining;
        if (source.activeSessionId == sessionId) {
          source.activeSessionId = firstSession(remaining)!;
        }
      }
      var index = activeId == null
          ? -1
          : tabs.indexWhere((item) => item.id == activeId);
      if (index < 0) {
        index = tabs.indexWhere((item) => item.id == target.id);
      }
      selected = tabs.isEmpty ? -1 : (index >= 0 ? index : 0);
    });
    _scheduleLayoutSave();
  }

  void _dropTab(String sourceTabId, String targetSessionId, SplitEdge edge) {
    final source = tabs.where((tab) => tab.id == sourceTabId).firstOrNull;
    final target = _tabForSession(targetSessionId);
    if (source == null || target == null || source.id == target.id) return;
    final activeId = _activeTabIndex >= 0 ? tabs[selected].id : null;
    setState(() {
      target.root = splitAt(target.root, targetSessionId, edge, source.root);
      target.activeSessionId =
          firstSession(source.root) ?? target.activeSessionId;
      tabs.remove(source);
      var index = activeId == null
          ? -1
          : tabs.indexWhere((item) => item.id == activeId);
      if (index < 0) {
        index = tabs.indexWhere((item) => item.id == target.id);
      }
      selected = tabs.isEmpty ? -1 : (index >= 0 ? index : 0);
    });
  }

  void _handleTabDrop(
    String sourceTabId,
    String targetSessionId,
    SplitEdge edge,
  ) {
    final target = _tabForSession(targetSessionId);
    if (target != null && target.id == sourceTabId) {
      // Dropping the current tab on one of its own panes means "split this
      // pane with another open session"; a tab cannot be merged with itself.
      unawaited(_splitSessionAt(targetSessionId, edge));
      return;
    }
    _dropTab(sourceTabId, targetSessionId, edge);
  }

  Future<void> _reconnect(_Session session) async {
    if (session.connected) return;
    final stored = session.profile;
    if (stored == null) {
      message('临时连接不保存凭据，请通过“新建连接”重新输入。');
      return;
    }
    HostProfile? latest;
    try {
      latest = (await hostStore.read())
          .where((host) => host.id == stored.id)
          .firstOrNull;
    } catch (e) {
      message('无法读取主机配置：${userFacingError(e)}');
      return;
    }
    if (latest == null) {
      message('主机「${stored.name}」已被删除，无法重连。');
      return;
    }
    await connect(latest, session);
  }

  void _reconnectById(String id) {
    final session = _sessionById(id);
    if (session != null) unawaited(_reconnect(session));
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  void _applyStartup(_Session session, HostProfile profile) {
    for (final line in profile.environment) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      final key = line.substring(0, separator);
      final value = line.substring(separator + 1);
      session.terminal.send(
        ' export $key=${_shellQuote(value)}\n',
        record: false,
      );
    }
    final command = profile.startupCommand.trim();
    if (command.isNotEmpty) {
      session.terminal.send(' $command\n', record: false);
    }
  }

  Future<File> _layoutFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/workspace-layout.json',
  );

  void _scheduleLayoutSave() {
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_saveLayout()),
    );
  }

  Future<void> _saveLayout() async {
    try {
      final descriptors = <String, Map<String, Object?>>{};
      for (final session in sessions) {
        if (session.hostId.isEmpty || session.profile == null) continue;
        descriptors[session.id] = {
          'hostId': session.hostId,
          'host': session.host,
          'username': session.username,
        };
      }
      final savedTabs = <Map<String, Object?>>[];
      int? savedSelected;
      for (var index = 0; index < tabs.length; index++) {
        final tab = tabs[index];
        final ids = sessionIdsOrdered(tab.root);
        if (ids.any((id) => !descriptors.containsKey(id))) continue;
        if (index == selected) savedSelected = savedTabs.length;
        final active = descriptors[tab.activeSessionId];
        savedTabs.add({
          if (tab.customName != null && tab.customName!.isNotEmpty)
            'name': tab.customName,
          'activeHostId': active?['hostId'],
          'root': encodePaneNode(tab.root, (id) => descriptors[id]!),
        });
      }
      final file = await _layoutFile();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'tabs': savedTabs,
          'selected': savedSelected ?? 0,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (_) {
      // Layout persistence is best-effort and never blocks the workspace.
    }
  }

  Future<void> _restoreLayout() async {
    if (_restoredLayout) return;
    _restoredLayout = true;
    try {
      if (tabs.isNotEmpty || sessions.isNotEmpty) return;
      final file = await _layoutFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return;
      final rawTabs = decoded['tabs'];
      if (rawTabs is! List || rawTabs.isEmpty) return;
      final hosts = await hostStore.read();
      if (!mounted || tabs.isNotEmpty || sessions.isNotEmpty) return;
      final byId = {for (final host in hosts) host.id: host};
      final restoredSessions = <_Session>[];
      final restoredTabs = <WorkspaceTab>[];
      for (final raw in rawTabs) {
        if (raw is! Map) continue;
        final tabSessions = <_Session>[];
        final root = decodePaneNode(raw['root'], (descriptor) {
          final hostId = descriptor['hostId'];
          final host = hostId is String ? byId[hostId] : null;
          if (host == null) return null;
          final terminal = TerminalSession.offline(
            host: host.host,
            username: host.username,
            onEnded: () {},
          );
          final session = _Session(
            terminal.connectionId,
            host.host,
            host.username,
            host.id,
            terminal,
            profile: host,
          );
          tabSessions.add(session);
          return session.id;
        });
        if (root == null) continue;
        final ids = sessionIdsOrdered(root);
        final activeHostId = raw['activeHostId'];
        final active = tabSessions
            .where(
              (session) =>
                  ids.contains(session.id) && session.hostId == activeHostId,
            )
            .firstOrNull;
        restoredSessions.addAll(tabSessions);
        restoredTabs.add(
          WorkspaceTab(
            id: HostProfile.newId(),
            root: root,
            activeSessionId: active?.id ?? ids.first,
            customName: raw['name'] is String ? raw['name'] as String : null,
          ),
        );
      }
      if (restoredTabs.isEmpty || !mounted) return;
      final selectedRaw = decoded['selected'];
      setState(() {
        sessions.addAll(restoredSessions);
        tabs.addAll(restoredTabs);
        selected = selectedRaw is num
            ? selectedRaw.toInt().clamp(0, tabs.length - 1)
            : 0;
      });
    } catch (_) {
      // A corrupt or unavailable layout must not prevent manual use.
    }
  }

  void _handleShortcut(String action, int? index) {
    if (!mounted) return;
    if (action == 'new') {
      unawaited(connect());
    } else if (action == 'close-tab') {
      if (_activeTabIndex >= 0) unawaited(closeTab(tabs[selected]));
    } else if (action == 'tab' && index != null) {
      if (index >= 0 && index < tabs.length) {
        setState(() => selected = index);
        _scheduleLayoutSave();
      }
    } else if (action == 'next-tab' || action == 'prev-tab') {
      if (tabs.length < 2) return;
      final step = action == 'next-tab' ? 1 : -1;
      setState(() => selected = (selected + step + tabs.length) % tabs.length);
      _scheduleLayoutSave();
    } else if (action == 'sessions') {
      unawaited(showSessionPicker());
    }
  }

  Future<void> _autoCheckUpdates() async {
    if (!mounted) return;
    final info = await checkForUpdate();
    if (!mounted || info == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('发现 W Term 新版本 ${info.version}'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () => launchUrl(
            Uri.parse(info.url),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  }

  Future<void> _checkUpdates() async {
    final info = await checkForUpdate();
    if (!mounted) return;
    if (info == null) {
      message('当前已是最新版本或无法连接更新服务（$appVersion）。');
      return;
    }
    final platform = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
        ? 'macos'
        : null;
    final asset = platform == null ? null : info.assetFor(platform);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发现新版本 ${info.version}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              info.notes.trim().isEmpty ? '请前往发布页查看更新内容。' : info.notes,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'later'),
            child: const Text('稍后'),
          ),
          if (asset != null)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'download'),
              child: const Text('下载并打开'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'open'),
            child: const Text('打开发布页'),
          ),
        ],
      ),
    );
    if (choice == 'download' && asset != null) {
      message('正在下载 ${asset.name}…');
      try {
        final file = await downloadUpdateAsset(asset);
        if (!mounted) return;
        if (Platform.isMacOS) {
          await Process.run('open', [file.path]);
        } else if (Platform.isWindows) {
          await Process.run('explorer', [file.path]);
        }
        message('安装包已下载并打开：${file.path}');
      } catch (e) {
        if (mounted) message('下载更新失败：${userFacingError(e)}');
      }
    } else if (choice == 'open') {
      await launchUrl(
        Uri.parse(info.url),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  Future<void> showSessionPicker() async {
    if (sessions.isEmpty) {
      message('当前没有已打开的终端。');
      return;
    }
    final activeId = _activeTabIndex >= 0
        ? tabs[selected].activeSessionId
        : null;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('已打开的终端'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final session in sessions)
                ListTile(
                  leading: Icon(
                    session.connected ? Icons.terminal : Icons.link_off,
                    size: 18,
                  ),
                  title: Text(
                    '${session.username}@${session.host}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_tabForSession(session.id) == null ? '未分组' : _tabTitle(_tabForSession(session.id)!)}'
                    '${session.connected ? '' : ' · 已断开'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: session.id == activeId
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.pop(context, session.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final tab = _tabForSession(chosen);
    if (tab == null) return;
    setState(() {
      selected = tabs.indexOf(tab);
      tab.activeSessionId = chosen;
    });
    _scheduleLayoutSave();
  }

  Future<void> _setBroadcastScope(BroadcastScope scope) async {
    if (scope == broadcastScope) return;
    if (scope == BroadcastScope.all) {
      final count = sessions.where((session) => session.connected).length;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('向所有已连接会话广播输入？'),
          content: Text(
            '键盘输入将同时写入 $count 个已连接终端（包含当前终端）。'
            '请确认没有正在执行的敏感命令。可随时从终端工具栏关闭广播。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始广播'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => broadcastScope = scope);
  }

  Future<void> _splitSession(String targetSessionId, Axis axis) =>
      _splitSessionAt(targetSessionId, edgeForAxis(axis));

  Future<void> _splitSessionAt(String targetSessionId, SplitEdge edge) async {
    final targetTab = _tabForSession(targetSessionId);
    if (targetTab == null) return;
    final inside = sessionIds(targetTab.root);
    final candidates = sessions
        .where((session) => !inside.contains(session.id))
        .toList();
    if (candidates.isEmpty) {
      message('没有其他已打开的会话。请先连接另一台主机，或把另一个标签拖到当前窗格边缘。');
      return;
    }
    final horizontal = edge == SplitEdge.left || edge == SplitEdge.right;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(horizontal ? '左右双分屏' : '上下双分屏'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final session in candidates)
                ListTile(
                  leading: Icon(
                    session.connected ? Icons.dns_outlined : Icons.link_off,
                    size: 18,
                  ),
                  title: Text(
                    '${session.username}@${session.host}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(session.connected ? '已连接' : '已断开（可查看保留输出）'),
                  onTap: () => Navigator.pop(context, session.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    _moveSessionToSplit(chosen, targetSessionId, edge);
  }

  Future<void> _splitFour(WorkspaceTab tab) async {
    final inside = sessionIdsOrdered(tab.root);
    if (inside.length >= 4) {
      message('当前标签已有 4 个窗格。');
      return;
    }
    final need = 4 - inside.length;
    final candidates = sessions
        .where((session) => !inside.contains(session.id))
        .toList();
    if (candidates.length < need) {
      message('四宫格需要 4 个已打开会话，当前还缺 $need 个。请先打开更多连接。');
      return;
    }
    final chosen = await _pickSessions(candidates, need);
    if (chosen == null || !mounted) return;
    final activeId = tab.activeSessionId;
    setState(() {
      for (final id in chosen) {
        _detachSession(id);
      }
      final existing = sessionIdsOrdered(tab.root);
      final ordered = <String>[
        if (existing.contains(activeId)) activeId,
        ...existing.where((id) => id != activeId),
        ...chosen,
      ].take(4).toList();
      tab.root = fourPane(ordered);
      tab.activeSessionId = ordered.first;
      selected = tabs.indexOf(tab);
    });
    _scheduleLayoutSave();
  }

  Future<List<String>?> _pickSessions(List<_Session> candidates, int need) {
    final selected = <String>{};
    return showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('四宫格分屏'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('还需选择 $need 个已打开会话，确认后将移动到当前标签。'),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final session in candidates)
                        CheckboxListTile(
                          value: selected.contains(session.id),
                          onChanged:
                              !selected.contains(session.id) &&
                                  selected.length >= need
                              ? null
                              : (value) => update(() {
                                  if (value == true) {
                                    selected.add(session.id);
                                  } else {
                                    selected.remove(session.id);
                                  }
                                }),
                          secondary: Icon(
                            session.connected
                                ? Icons.dns_outlined
                                : Icons.link_off,
                            size: 18,
                          ),
                          title: Text(
                            '${session.username}@${session.host}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            session.connected ? '已连接' : '已断开（可查看保留输出）',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.length == need
                  ? () => Navigator.pop(context, selected.toList())
                  : null,
              child: const Text('创建四宫格'),
            ),
          ],
        ),
      ),
    );
  }

  void _detachSession(String id) {
    final source = _tabForSession(id);
    if (source == null) return;
    final remaining = removeSession(source.root, id);
    if (remaining == null) {
      tabs.remove(source);
      return;
    }
    source.root = remaining;
    if (source.activeSessionId == id) {
      source.activeSessionId = firstSession(remaining)!;
    }
  }

  Widget _menuRow(IconData icon, String label, {Widget? trailing}) => Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(label)),
      ?trailing,
    ],
  );

  RelativeRect _menuPosition(Offset origin) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.sizeOf(context);
    const menuWidth = 220.0, menuHeight = 340.0;
    final dx = origin.dx.clamp(
      8.0,
      (size.width - menuWidth).clamp(8.0, size.width),
    );
    final dy = origin.dy.clamp(
      8.0,
      (size.height - menuHeight).clamp(8.0, size.height),
    );
    return RelativeRect.fromLTRB(dx, dy, size.width - dx, size.height - dy);
  }

  Future<void> _showTabMenu(WorkspaceTab tab, Offset position) async {
    final index = tabs.indexOf(tab);
    if (index < 0) return;
    if (selected != index) setState(() => selected = index);
    final paneCount = sessionIds(tab.root).length;
    final choice = await showMenu<String>(
      context: context,
      position: _menuPosition(position),
      items: [
        PopupMenuItem(
          value: 'rename',
          child: _menuRow(Icons.edit_outlined, '重命名标签'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'split',
          child: _menuRow(
            Icons.call_split,
            '分屏',
            trailing: const Icon(Icons.chevron_right, size: 18),
          ),
        ),
        if (paneCount > 1)
          PopupMenuItem(
            value: 'unsplit',
            child: _menuRow(Icons.close_fullscreen, '拆回当前窗格'),
          ),
        if (paneCount > 1)
          PopupMenuItem(
            value: 'close-pane',
            child: _menuRow(Icons.grid_off_outlined, '关闭当前窗格'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'close', child: _menuRow(Icons.close, '关闭标签')),
        if (tabs.length > 1)
          PopupMenuItem(
            value: 'close-others',
            child: _menuRow(Icons.tab_unselected, '关闭其他标签'),
          ),
        PopupMenuItem(value: 'new', child: _menuRow(Icons.add, '新建连接')),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'rename') {
      await _renameTab(tab);
    } else if (choice == 'split') {
      await _showSplitMenu(tab, position);
    } else if (choice == 'unsplit') {
      _splitBack(tab.activeSessionId);
    } else if (choice == 'close-pane') {
      await _closePane(tab.activeSessionId);
    } else if (choice == 'close') {
      await closeTab(tab);
    } else if (choice == 'close-left') {
      await _closeTabs(tabs.sublist(0, tabs.indexOf(tab)));
    } else if (choice == 'close-right') {
      await _closeTabs(tabs.sublist(tabs.indexOf(tab) + 1));
    } else if (choice == 'close-others') {
      await _closeOtherTabs(tab);
    } else if (choice == 'close-disconnected') {
      await _closeTabs(
        tabs
            .where(
              (item) =>
                  sessionIds(item.root)
                      .every((id) => _sessionById(id)?.connected != true),
            )
            .toList(),
      );
    } else if (choice == 'new') {
      await connect();
    }
  }

  Future<void> _showSplitMenu(WorkspaceTab tab, Offset position) async {
    final choice = await showMenu<String>(
      context: context,
      position: _menuPosition(position + const Offset(200, 24)),
      items: [
        PopupMenuItem(
          value: 'horizontal',
          child: _menuRow(Icons.vertical_split, '左右双分屏'),
        ),
        PopupMenuItem(
          value: 'vertical',
          child: _menuRow(Icons.horizontal_split, '上下双分屏'),
        ),
        PopupMenuItem(value: 'grid', child: _menuRow(Icons.grid_view, '四宫格分屏')),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'grid') {
      await _splitFour(tab);
      return;
    }
    await _splitSessionAt(
      tab.activeSessionId,
      choice == 'horizontal' ? SplitEdge.right : SplitEdge.bottom,
    );
  }

  Future<void> _closeTabs(List<WorkspaceTab> doomedTabs) async {
    if (doomedTabs.isEmpty) return;
    final ids = doomedTabs.expand((tab) => sessionIds(tab.root)).toSet();
    final doomed = ids.map(_sessionById).whereType<_Session>().toList();
    final connected = doomed.where((session) => session.connected).length;
    if (connected > 0) {
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('关闭 ${doomedTabs.length} 个标签并断开 $connected 个会话？'),
          content: const Text('这些标签中的窗格、文件传输和转发将结束。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('断开'),
            ),
          ],
        ),
      );
      if (close != true || !mounted) return;
    }
    final selectedId = _activeTabIndex >= 0 ? tabs[selected].id : null;
    setState(() {
      tabs.removeWhere(doomedTabs.contains);
      sessions.removeWhere((session) => ids.contains(session.id));
      if (tabs.isEmpty) {
        selected = -1;
      } else {
        final index = selectedId == null
            ? -1
            : tabs.indexWhere((tab) => tab.id == selectedId);
        selected = index >= 0 ? index : 0;
      }
    });
    _scheduleLayoutSave();
    await _disposeSessions(doomed);
  }

  Future<void> _closeOtherTabs(WorkspaceTab keep) async {
    final others = tabs.where((tab) => tab.id != keep.id).toList();
    if (others.isEmpty) return;
    final ids = others.expand((tab) => sessionIds(tab.root)).toSet();
    final doomed = ids.map(_sessionById).whereType<_Session>().toList();
    final connected = doomed.where((session) => session.connected).length;
    if (connected > 0) {
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('断开其他标签中的 $connected 个会话？'),
          content: const Text('当前标签将保留，其余标签及其 SSH 会话会被断开。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('断开'),
            ),
          ],
        ),
      );
      if (close != true || !mounted) return;
    }
    setState(() {
      tabs.removeWhere((tab) => tab.id != keep.id);
      sessions.removeWhere((session) => ids.contains(session.id));
      selected = tabs.indexOf(keep);
    });
    _scheduleLayoutSave();
    await _disposeSessions(doomed);
  }

  Future<void> _disposeSessions(Iterable<_Session> doomed) async {
    for (final session in doomed) {
      await session.terminal.close();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => session.terminal.dispose(),
      );
    }
  }

  Future<void> _renameTab(WorkspaceTab tab) async {
    final controller = TextEditingController(
      text: tab.customName ?? _tabTitle(tab),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '标签名称',
            helperText: '留空恢复为当前主机名',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (name == null || !mounted) return;
    setState(() {
      final value = name.trim();
      tab.customName = value.isEmpty ? null : value;
    });
    _scheduleLayoutSave();
  }

  Future<void> showKnownHosts() async {
    try {
      final entries = await trust.read();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('已信任的服务器'),
            content: SizedBox(
              width: 560,
              child: entries.isEmpty
                  ? const Text('连接并验证服务器后，其指纹将保存在这里。')
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final entry in entries.entries)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(entry.key),
                              subtitle: SelectableText(
                                entry.value,
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: IconButton(
                                tooltip: '忘记指纹',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final allow = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('忘记此服务器指纹？'),
                                      content: const Text(
                                        '仅在已核实服务器身份变化时操作。下次连接需要重新验证。',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('取消'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('忘记'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (allow != true) return;
                                  try {
                                    await trust.forget(entry.key);
                                    if (context.mounted) {
                                      update(() => entries.remove(entry.key));
                                    }
                                  } catch (e) {
                                    message('钥匙串操作失败：${userFacingError(e)}');
                                  }
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      message('无法读取钥匙串：${userFacingError(e)}');
    }
  }

  PopupMenuItem<String> popupItem(String value, IconData icon, String label) =>
      PopupMenuItem<String>(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 10),
            Text(label),
          ],
        ),
      );

  Future<void> sidebarAction(String action, bool drawer) async {
    if (drawer) scaffoldKey.currentState?.closeDrawer();
    switch (action) {
      case 'snippets':
        if (hostStore is SnippetStore) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => SnippetsDialog(
              store: hostStore as SnippetStore,
              allowInsert: false,
            ),
          );
        }
      case 'sync':
        if (hostStore is SyncStore) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => SyncDialog(store: hostStore as SyncStore),
          );
          if (!mounted) return;
          setState(() => identitiesEpoch++);
          await hostPanelKey.currentState?.load();
        }
      case 'proxy':
        if (hostStore is ConnectionProxyStore) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) =>
                ProxyDialog(store: hostStore as ConnectionProxyStore),
          );
        }
      case 'vault':
        if (hostStore is VaultMaintenance) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => VaultSettings(store: hostStore as VaultMaintenance),
          );
          if (mounted) await hostPanelKey.currentState?.load();
        }
      case 'known':
        await showKnownHosts();
      case 'sessions':
        await showSessionPicker();
      case 'history':
        await showDialog<void>(
          context: context,
          builder: (_) => CommandHistoryDialog(history: commandHistory),
        );
      case 'update':
        await _checkUpdates();
      case 'lock':
        widget.onLock?.call();
    }
  }

  List<PopupMenuEntry<String>> _settingsItems() => [
    popupItem('sessions', Icons.list_alt, '已打开终端'),
    popupItem('history', Icons.history, '命令历史'),
    popupItem('update', Icons.system_update, '检查更新'),
    if (hostStore is SnippetStore) popupItem('snippets', Icons.code, '命令片段'),
    if (hostStore is SyncStore) popupItem('sync', Icons.sync, 'GitHub 同步'),
    if (hostStore is ConnectionProxyStore)
      popupItem('proxy', Icons.route_outlined, '连接代理'),
    if (hostStore is VaultMaintenance)
      popupItem('vault', Icons.security_outlined, '保险库与备份'),
    popupItem('known', Icons.verified_user_outlined, '服务器指纹'),
    if (widget.onLock != null) popupItem('lock', Icons.lock_outline, '锁定保险库'),
  ];

  Widget _collapsedSidebar() => Container(
    width: 48,
    decoration: BoxDecoration(
      border: Border(
        right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Column(
      children: [
        const SizedBox(height: 8),
        IconButton(
          tooltip: '展开主机列表',
          icon: const Icon(Icons.chevron_right, size: 20),
          onPressed: () => setState(() => sidebarCollapsed = false),
        ),
        IconButton(
          tooltip: '新建连接',
          icon: const Icon(Icons.add, size: 20),
          onPressed: connecting ? null : connect,
        ),
        const Spacer(),
        PopupMenuButton<String>(
          tooltip: '设置与工具',
          icon: const Icon(Icons.tune, size: 18),
          onSelected: (value) => sidebarAction(value, false),
          itemBuilder: (_) => _settingsItems(),
        ),
        if (widget.onLock != null)
          IconButton(
            tooltip: '锁定保险库',
            icon: const Icon(Icons.lock_outline, size: 18),
            onPressed: widget.onLock,
          ),
        const SizedBox(height: 8),
      ],
    ),
  );

  Widget _sidebarResizeHandle() => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => setState(() {
        sidebarWidth = (sidebarWidth + details.delta.dx).clamp(200, 480);
      }),
      child: SizedBox(
        width: 6,
        child: Center(
          child: Container(
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
    ),
  );

  Widget sidebar({bool drawer = false, double width = 272}) => SizedBox(
    width: width,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 8, 12),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'W Term',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (!drawer)
                    IconButton(
                      tooltip: '收起主机列表',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_left, size: 20),
                      onPressed: () => setState(() => sidebarCollapsed = true),
                    ),
                ],
              ),
            ),
            if (hostStore is IdentityStore)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('主机')),
                    ButtonSegment(value: true, label: Text('身份 / 密钥')),
                  ],
                  selected: {showIdentities},
                  onSelectionChanged: (v) =>
                      setState(() => showIdentities = v.first),
                ),
              ),
            Expanded(
              child: showIdentities && hostStore is IdentityStore
                  ? IdentitiesPane(
                      key: ValueKey(identitiesEpoch),
                      store: hostStore as IdentityStore,
                    )
                  : HostsPage(
                      key: hostPanelKey,
                      store: hostStore,
                      embedded: true,
                      onConnect: (profile) {
                        if (drawer) scaffoldKey.currentState?.closeDrawer();
                        connect(profile);
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
              child: Row(
                children: [
                  const AppVersionLabel(),
                  const Spacer(),
                  PopupMenuButton<String>(
                    tooltip: '设置与工具',
                    icon: const Icon(Icons.tune, size: 18),
                    onSelected: (value) => sidebarAction(value, drawer),
                    itemBuilder: (_) => _settingsItems(),
                  ),
                  if (widget.onLock != null)
                    IconButton(
                      tooltip: '锁定保险库',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.lock_outline, size: 18),
                      onPressed: () {
                        if (drawer) scaffoldKey.currentState?.closeDrawer();
                        widget.onLock?.call();
                      },
                    ),
                ],
              ),
            ),
          ],
        );
        return constraints.maxHeight < 480
            ? SingleChildScrollView(
                child: SizedBox(height: 600, child: content),
              )
            : content;
      },
    ),
  );

  Widget _tabItem(WorkspaceTab tab, int index, bool wide) {
    final count = sessionIds(tab.root).length;
    final active = _sessionById(tab.activeSessionId);
    final isSelected = selected == index;
    final scheme = Theme.of(context).colorScheme;
    final draggable = Draggable<String>(
      data: tab.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 4,
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            _tabTitle(tab),
            style: TextStyle(fontSize: 12, color: scheme.onInverseSurface),
          ),
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) =>
            _showTabMenu(tab, details.globalPosition),
        onLongPressStart: (details) =>
            _showTabMenu(tab, details.globalPosition),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            setState(() => selected = index);
            _scheduleLayoutSave();
          },
          onDoubleTap: () => _renameTab(tab),
          child: Tooltip(
            message:
                '${active?.username ?? ''}@${active?.host ?? ''}\n'
                '拖动标签到窗格边缘分屏；双击重命名；右键或长按更多',
            child: Container(
              constraints: BoxConstraints(maxWidth: wide ? 150 : 120),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.circle,
                    size: 6,
                    color: active?.connected == true
                        ? scheme.primary
                        : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _tabTitle(tab),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (count > 1) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(fontSize: 9),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      key: ValueKey('tab-${tab.id}'),
      padding: const EdgeInsets.fromLTRB(3, 3, 0, 3),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) => details.data != tab.id,
        onAcceptWithDetails: (details) =>
            _dropTab(details.data, tab.activeSessionId, SplitEdge.right),
        builder: (context, candidate, rejected) => Material(
          color: candidate.isNotEmpty
              ? scheme.primary.withValues(alpha: .22)
              : isSelected
              ? scheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Tooltip(
                  message: '拖动排序',
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.drag_indicator,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              draggable,
              IconButton(
                tooltip: '关闭标签',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(
                  width: wide ? 28 : 40,
                  height: wide ? 28 : 38,
                ),
                icon: const Icon(Icons.close, size: 14),
                onPressed: () => closeTab(tab),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabView(WorkspaceTab tab) => _TabView(
    key: ValueKey('tabview-${tab.id}'),
    tab: tab,
    active: _activeTabIndex >= 0 && tabs[selected] == tab,
    sessions: sessions,
    snippets: hostStore is SnippetStore ? hostStore as SnippetStore : null,
    ruleStore: hostStore is ForwardRuleStore
        ? hostStore as ForwardRuleStore
        : null,
    broadcastScope: broadcastScope,
    onBroadcastChanged: _setBroadcastScope,
    onShortcut: _handleShortcut,
    onReconnect: _reconnectById,
    onActivate: (sessionId) {
      if (tab.activeSessionId != sessionId) {
        setState(() => tab.activeSessionId = sessionId);
        _scheduleLayoutSave();
      }
    },
    onSplit: _splitSession,
    onSplitBack: _splitBack,
    onClosePane: _closePane,
    onDropTab: _handleTabDrop,
  );

  Widget sessionBar(bool wide) => SizedBox(
    key: const ValueKey('session-bar'),
    height: wide ? 36 : 44,
    child: Row(
      children: [
        if (!wide)
          IconButton(
            tooltip: '主机管理',
            icon: const Icon(Icons.menu, size: 20),
            onPressed: () => scaffoldKey.currentState?.openDrawer(),
          ),
        Expanded(
          child: tabs.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Text('工作区', style: TextStyle(fontSize: 12)),
                )
              : ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  itemCount: tabs.length,
                  onReorderItem: _reorderTab,
                  itemBuilder: (context, index) =>
                      _tabItem(tabs[index], index, wide),
                ),
        ),
        IconButton(
          tooltip: '新建连接',
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add, size: 19),
          onPressed: connecting ? null : connect,
        ),
      ],
    ),
  );
  Widget emptyState() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer
                    .withValues(alpha: .4),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                Icons.terminal_rounded,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              '你的服务器，触手可及。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: -.8,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '打开终端、浏览文件。\n从一条安全的 SSH 连接开始。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                height: 1.8,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: connecting ? null : connect,
              icon: const Icon(Icons.add),
              label: const Text('连接服务器'),
            ),
            const SizedBox(height: 40),
            const Wrap(
              spacing: 22,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                _Feature(Icons.fingerprint, '指纹验证'),
                _Feature(Icons.key_outlined, '密码 / 私钥'),
                _Feature(Icons.folder_outlined, 'SFTP 文件传输'),
              ],
            ),
            const SizedBox(height: 32),
            const Text(
              '密码与私钥加密保存在本地保险库。\n双击左侧主机即可连接。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.7, color: Colors.grey),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): connect,
      },
      child: Scaffold(
        key: scaffoldKey,
        drawer: wide
            ? null
            : Drawer(width: 292, child: SafeArea(child: sidebar(drawer: true))),
        body: SafeArea(
          child: Column(
            children: [
              if (connecting && !preparing)
                Material(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            status,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed: cancelConnect,
                          child: const Text('取消'),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    if (wide) ...[
                      if (sidebarCollapsed)
                        _collapsedSidebar()
                      else ...[
                        sidebar(width: sidebarWidth),
                        _sidebarResizeHandle(),
                      ],
                    ],
                    Expanded(
                      child: Column(
                        children: [
                          sessionBar(wide),
                          const Divider(height: 1),
                          Expanded(
                            child: tabs.isEmpty
                                ? emptyState()
                                : IndexedStack(
                                    index: selected.clamp(0, tabs.length - 1),
                                    children: [
                                      for (final tab in tabs) _tabView(tab),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Feature(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 17, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 7),
      Text(text, style: const TextStyle(fontSize: 12)),
    ],
  );
}

class _TabView extends StatefulWidget {
  final WorkspaceTab tab;
  final List<_Session> sessions;
  final SnippetStore? snippets;
  final ForwardRuleStore? ruleStore;
  final bool active;
  final BroadcastScope broadcastScope;
  final ValueChanged<BroadcastScope> onBroadcastChanged;
  final void Function(String action, int? index)? onShortcut;
  final ValueChanged<String> onReconnect;
  final ValueChanged<String> onActivate;
  final void Function(String sessionId, Axis axis) onSplit;
  final ValueChanged<String> onSplitBack;
  final ValueChanged<String> onClosePane;
  final void Function(
    String sourceTabId,
    String targetSessionId,
    SplitEdge edge,
  )
  onDropTab;
  const _TabView({
    super.key,
    required this.tab,
    required this.sessions,
    this.snippets,
    this.ruleStore,
    required this.active,
    required this.broadcastScope,
    required this.onBroadcastChanged,
    this.onShortcut,
    required this.onReconnect,
    required this.onActivate,
    required this.onSplit,
    required this.onSplitBack,
    required this.onClosePane,
    required this.onDropTab,
  });
  @override
  State<_TabView> createState() => _TabViewState();
}

class _TabViewState extends State<_TabView> {
  bool files = false, openedFiles = false;
  double filePaneWidth = 340;
  final _filesKeys = <String, GlobalKey<FilesPaneState>>{};
  _Session? _byId(String id) =>
      widget.sessions.where((session) => session.id == id).firstOrNull;

  GlobalKey<FilesPaneState> _filesKey(String id) =>
      _filesKeys.putIfAbsent(id, GlobalKey<FilesPaneState>.new);

  void _fileRailAction(String action, String sessionId) {
    setState(() {
      files = true;
      openedFiles = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = _filesKeys[sessionId]?.currentState;
      if (action == 'upload') state?.upload();
      if (action == 'refresh') state?.refresh();
    });
  }

  Widget _fileRail(String sessionId) => Container(
    width: 44,
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Column(
      children: [
        const SizedBox(height: 4),
        IconButton(
          tooltip: '显示文件',
          icon: const Icon(Icons.folder_open, size: 18),
          onPressed: () => setState(() => files = true),
        ),
        IconButton(
          tooltip: '上传文件',
          icon: const Icon(Icons.upload_file, size: 18),
          onPressed: () => _fileRailAction('upload', sessionId),
        ),
        IconButton(
          tooltip: '刷新文件列表',
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: () => _fileRailAction('refresh', sessionId),
        ),
      ],
    ),
  );

  Widget _fileResizeHandle() => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => setState(() {
        filePaneWidth = (filePaneWidth - details.delta.dx).clamp(240, 560);
      }),
      child: SizedBox(
        width: 6,
        child: Center(
          child: Container(
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final active =
        _byId(widget.tab.activeSessionId) ??
        _byId(firstSession(widget.tab.root) ?? '');
    if (active == null) return const SizedBox.shrink();
    final forwarding = SessionForwardingStore(
      connectionId: active.id,
      hostId: active.hostId,
      rules: widget.ruleStore,
    );
    return LayoutBuilder(
      builder: (context, size) {
        final split = size.maxWidth >= 850;
        final panes = _PaneTree(
          node: widget.tab.root,
          tab: widget.tab,
          sessions: widget.sessions,
          snippets: widget.snippets,
          active: widget.active,
          broadcastScope: widget.broadcastScope,
          onBroadcastChanged: widget.onBroadcastChanged,
          onShortcut: widget.onShortcut,
          onReconnect: widget.onReconnect,
          onActivate: widget.onActivate,
          onSplit: widget.onSplit,
          onSplitBack: widget.onSplitBack,
          onClosePane: widget.onClosePane,
          onDropTab: widget.onDropTab,
          onOpenFiles: () => setState(() {
            files = true;
            openedFiles = true;
          }),
          onLayoutChanged: () {
            if (mounted) setState(() {});
          },
        );
        final filesPane = FilesPane(
          key: _filesKey(active.id),
          connectionId: active.id,
          dropActive: widget.active && files && active.connected,
          followedPath: active.terminal.currentDirectory,
        );
        return Column(
          children: [
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${active.username}@${active.host}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '端口转发',
                    icon: const Icon(Icons.settings_ethernet, size: 18),
                    onPressed: !active.connected
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => ForwardingDialog(
                              store: forwarding,
                              hostId: active.hostId.isEmpty
                                  ? null
                                  : active.hostId,
                              hostName: active.host,
                            ),
                          ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() {
                      files = !files;
                      openedFiles = true;
                    }),
                    icon: Icon(
                      files ? Icons.terminal : Icons.folder_outlined,
                      size: 17,
                    ),
                    label: Text(files ? '终端' : '文件'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Offstage(offstage: files && !split, child: panes),
                        if (openedFiles && !split)
                          Offstage(offstage: !files, child: filesPane),
                      ],
                    ),
                  ),
                  if (openedFiles && split) ...[
                    if (files) _fileResizeHandle(),
                    if (files)
                      SizedBox(width: filePaneWidth, child: filesPane)
                    else
                      _fileRail(active.id),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PaneTree extends StatelessWidget {
  final PaneNode node;
  final WorkspaceTab tab;
  final List<_Session> sessions;
  final SnippetStore? snippets;
  final bool active;
  final BroadcastScope broadcastScope;
  final ValueChanged<BroadcastScope> onBroadcastChanged;
  final void Function(String action, int? index)? onShortcut;
  final ValueChanged<String> onReconnect;
  final ValueChanged<String> onActivate;
  final void Function(String sessionId, Axis axis) onSplit;
  final ValueChanged<String> onSplitBack;
  final ValueChanged<String> onClosePane;
  final void Function(
    String sourceTabId,
    String targetSessionId,
    SplitEdge edge,
  )
  onDropTab;
  final VoidCallback? onOpenFiles;
  final VoidCallback onLayoutChanged;
  const _PaneTree({
    required this.node,
    required this.tab,
    required this.sessions,
    this.snippets,
    required this.active,
    required this.broadcastScope,
    required this.onBroadcastChanged,
    this.onShortcut,
    required this.onReconnect,
    required this.onActivate,
    required this.onSplit,
    required this.onSplitBack,
    required this.onClosePane,
    required this.onDropTab,
    this.onOpenFiles,
    required this.onLayoutChanged,
  });

  _Session? _byId(String id) =>
      sessions.where((session) => session.id == id).firstOrNull;

  Widget _leaf(String sessionId) {
    final session = _byId(sessionId);
    if (session == null) return const SizedBox.shrink();
    final count = sessionIds(tab.root).length;
    final targetIds = broadcastTargetIds(
      sourceId: session.id,
      scope: broadcastScope,
      tabSessionIds: sessionIdsOrdered(tab.root),
      allSessionIds: sessions.map((item) => item.id),
      connectedSessionIds: {
        for (final item in sessions)
          if (item.connected) item.id,
      },
    );
    final byId = {for (final item in sessions) item.id: item};
    final targets = [
      for (final id in targetIds)
        if (byId[id] != null) byId[id]!.terminal,
    ];
    final pane = TerminalPane(
      key: ValueKey(session.id),
      session: session.terminal,
      snippets: snippets,
      active: active && tab.activeSessionId == session.id,
      broadcastScope: broadcastScope,
      broadcastTargets: targets,
      onBroadcastChanged: onBroadcastChanged,
      onShortcut: onShortcut,
      onReconnect: () => onReconnect(session.id),
      onOpenFiles: onOpenFiles,
      onActivate: () => onActivate(session.id),
      onSplitHorizontal: () => onSplit(session.id, Axis.horizontal),
      onSplitVertical: () => onSplit(session.id, Axis.vertical),
      onSplitBack: count > 1 ? () => onSplitBack(session.id) : null,
      onClosePane: () => onClosePane(session.id),
    );
    return _PaneDropSurface(
      targetSessionId: session.id,
      onDrop: onDropTab,
      child: pane,
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = node;
    if (current is SessionPane) return _leaf(current.sessionId);
    final split = current as SplitPane;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = split.axis == Axis.horizontal;
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        if (extent <= 0) return const SizedBox.shrink();
        final first = (split.fraction * 1000).round().clamp(120, 880);
        final second = 1000 - first;
        final divider = MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: horizontal
                ? (details) {
                    split.fraction =
                        (split.fraction + details.delta.dx / extent).clamp(
                          .15,
                          .85,
                        );
                    onLayoutChanged();
                  }
                : null,
            onVerticalDragUpdate: horizontal
                ? null
                : (details) {
                    split.fraction =
                        (split.fraction + details.delta.dy / extent).clamp(
                          .15,
                          .85,
                        );
                    onLayoutChanged();
                  },
            child: SizedBox(
              width: horizontal ? 6 : double.infinity,
              height: horizontal ? double.infinity : 6,
              child: Center(
                child: Container(
                  width: horizontal ? 1 : double.infinity,
                  height: horizontal ? double.infinity : 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
          ),
        );
        final firstChild = Expanded(
          flex: first,
          child: _PaneTree(
            node: split.first,
            tab: tab,
            sessions: sessions,
            snippets: snippets,
            active: active,
            broadcastScope: broadcastScope,
            onBroadcastChanged: onBroadcastChanged,
            onShortcut: onShortcut,
            onReconnect: onReconnect,
            onActivate: onActivate,
            onSplit: onSplit,
            onSplitBack: onSplitBack,
            onClosePane: onClosePane,
            onDropTab: onDropTab,
            onOpenFiles: onOpenFiles,
            onLayoutChanged: onLayoutChanged,
          ),
        );
        final secondChild = Expanded(
          flex: second,
          child: _PaneTree(
            node: split.second,
            tab: tab,
            sessions: sessions,
            snippets: snippets,
            active: active,
            broadcastScope: broadcastScope,
            onBroadcastChanged: onBroadcastChanged,
            onShortcut: onShortcut,
            onReconnect: onReconnect,
            onActivate: onActivate,
            onSplit: onSplit,
            onSplitBack: onSplitBack,
            onClosePane: onClosePane,
            onDropTab: onDropTab,
            onOpenFiles: onOpenFiles,
            onLayoutChanged: onLayoutChanged,
          ),
        );
        return horizontal
            ? Row(children: [firstChild, divider, secondChild])
            : Column(children: [firstChild, divider, secondChild]);
      },
    );
  }
}

class _PaneDropSurface extends StatefulWidget {
  final String targetSessionId;
  final void Function(
    String sourceTabId,
    String targetSessionId,
    SplitEdge edge,
  )
  onDrop;
  final Widget child;
  const _PaneDropSurface({
    required this.targetSessionId,
    required this.onDrop,
    required this.child,
  });
  @override
  State<_PaneDropSurface> createState() => _PaneDropSurfaceState();
}

class _PaneDropSurfaceState extends State<_PaneDropSurface> {
  final _boxKey = GlobalKey();
  SplitEdge? _hovering;

  RenderBox? get _box =>
      _boxKey.currentContext?.findRenderObject() as RenderBox?;

  Offset? _localOffset(Offset global) {
    final box = _box;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  SplitEdge _edgeAt(Offset local) =>
      nearestSplitEdge(local, _box?.size ?? Size.zero);

  void _track(Offset global) {
    final local = _localOffset(global);
    if (local == null) return;
    final edge = _edgeAt(local);
    if (edge != _hovering) setState(() => _hovering = edge);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final edge = _hovering;
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) => _track(details.offset),
      onLeave: (_) {
        if (_hovering != null) setState(() => _hovering = null);
      },
      onAcceptWithDetails: (details) {
        final target = _hovering ?? SplitEdge.right;
        setState(() => _hovering = null);
        widget.onDrop(details.data, widget.targetSessionId, target);
      },
      builder: (context, candidate, rejected) => Stack(
        key: _boxKey,
        fit: StackFit.expand,
        children: [
          widget.child,
          if (edge != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: switch (edge) {
                    SplitEdge.left => Alignment.centerLeft,
                    SplitEdge.right => Alignment.centerRight,
                    SplitEdge.top => Alignment.topCenter,
                    SplitEdge.bottom => Alignment.bottomCenter,
                  },
                  child: FractionallySizedBox(
                    widthFactor:
                        edge == SplitEdge.left || edge == SplitEdge.right
                        ? .5
                        : 1,
                    heightFactor:
                        edge == SplitEdge.top || edge == SplitEdge.bottom
                        ? .5
                        : 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .2),
                        border: Border.all(color: color, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
