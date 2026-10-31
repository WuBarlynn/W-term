import 'font_catalog.dart';
import 'interactive_auth.dart';
import 'connection_route.dart';
import 'forward_store.dart';
import 'plugins.dart';
import 'terminal_session.dart';
import 'terminal_appearance.dart';
import 'command_history.dart';
import 'update_checker.dart';
import 'session_handoff.dart';

import 'package:window_manager/window_manager.dart';

import 'workspace_layout.dart';
import 'proxy_store.dart';
import '../features/proxy_dialog.dart';
import '../features/plugin_settings_dialog.dart';
import '../features/settings_dialog.dart';
import '../features/terminal_appearance_dialog.dart';
import '../features/auth_challenge_dialog.dart';
import '../features/forwarding_dialog.dart';
import 'errors.dart';
import 'app_version_label.dart';
import 'host_store.dart';
import 'identity_store.dart';
import 'snippet_store.dart';
import 'sync_store.dart';
import 'synced_settings.dart';
import '../features/sync_dialog.dart';
import '../features/snippets_dialog.dart';
import '../features/command_history_dialog.dart';
import '../features/host_editor.dart';
import '../features/identities_pane.dart';
import '../features/vault_settings.dart';
import 'task_notifications.dart';
import 'auto_backup.dart';
import 'system_notifications.dart';
import 'sync_automation.dart';
import 'deep_links.dart';
import 'desktop_tray.dart';
import '../features/hosts_page.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xterm/zmodem.dart';

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
  bool showIdentities = false, sidebarCollapsed = false, focusMode = false;
  double sidebarWidth = 272;
  int identitiesEpoch = 0;
  final sessions = <_Session>[];
  final commandHistory = CommandHistory();
  final tabs = <WorkspaceTab>[];
  int selected = -1, attempt = 0;
  BroadcastScope broadcastScope = BroadcastScope.off;
  bool connecting = false, preparing = false;
  Timer? _layoutSaveTimer, _updateTimer, _autoSyncTimer;
  bool _autoSyncBusy = false;
  bool _restoredLayout = false;
  String status = '';
  String? pending;
  String? activeOperationId, connectionRootId;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(commandHistory.load());
    if (hostStore is VaultMaintenance) {
      unawaited(autoBackup.ensureRecent(hostStore as VaultMaintenance));
    }
    if (hostStore case final SyncedSettingsHost syncHost) {
      syncHost.attachSyncedSettings(
        exportSettings: SyncedSettings.export,
        importSettings: (json) async {
          await SyncedSettings.import(json);
          if (mounted) setState(() {});
        },
      );
    }
    _restartAutoSync();
    taskMonitor.addListener(_taskCompleted);
    trayConnectRequests.addListener(_trayConnectRequested);
    pendingDeepLink.addListener(_deepLinkReceived);
    const MethodChannel('dev.wterm/biometrics')
        .setMethodCallHandler(_handleNativeMethod);
    if (Platform.isWindows) {
      unawaited(
        const WindowMethodChannel(
          'dev.wterm/window-recall',
          mode: ChannelMode.unidirectional,
        ).setMethodCallHandler(_handleWindowRecall),
      );
    }
    unawaited(_restoreLayout());
    if (supportsDesktopUpdates) {
      _updateTimer = Timer(const Duration(seconds: 6), _autoCheckUpdates);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    taskMonitor.removeListener(_taskCompleted);
    taskMonitor.cancelAll();
    trayConnectRequests.removeListener(_trayConnectRequested);
    pendingDeepLink.removeListener(_deepLinkReceived);
    const MethodChannel('dev.wterm/biometrics').setMethodCallHandler(null);
    if (Platform.isWindows) {
      unawaited(
        const WindowMethodChannel(
          'dev.wterm/window-recall',
          mode: ChannelMode.unidirectional,
        ).setMethodCallHandler(null),
      );
    }
    _layoutSaveTimer?.cancel();
    _updateTimer?.cancel();
    _autoSyncTimer?.cancel();
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

  Future<void> openLocalTerminal() async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      message('本地终端仅支持桌面平台。');
      return;
    }
    final username = Platform.isWindows
        ? (Platform.environment['USERNAME'] ?? 'local')
        : (Platform.environment['USER'] ?? 'local');
    late final TerminalSession terminal;
    terminal = TerminalSession.local(
      host: 'localhost',
      username: username,
      onEnded: () => _terminalEnded(terminal.connectionId),
      onActivity: () => taskMonitor.activity(terminal.connectionId),
      onCommandFinished: (exitCode) => taskMonitor.commandFinished(
        terminal.connectionId,
        exitCode: exitCode,
      ),
      onCommand: (command) {
        unawaited(
          commandHistory.record(
            command: command,
            host: 'localhost',
            username: username,
          ),
        );
        taskMonitor.commandSubmitted(
          terminal.connectionId,
          command,
          title: '$username@localhost',
        );
      },
    );
    final session = _Session(
      terminal.connectionId,
      'localhost',
      username,
      '',
      terminal,
    );
    _bindInputRouting(session);
    setState(() {
      sessions.add(session);
      tabs.add(
        WorkspaceTab(
          id: HostProfile.newId(),
          root: SessionPane(session.id),
          activeSessionId: session.id,
        ),
      );
      selected = tabs.length - 1;
    });
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
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontFamilyFallback: monoFontFallback,
                        fontSize: 13,
                      ),
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
        hostId: hops.last.hostId,
        onEnded: () {
          taskMonitor.sessionClosed(connectedId);
          _terminalEnded(connectedId);
        },
        onActivity: () => taskMonitor.activity(connectedId),
        onCommandFinished: (exitCode) =>
            taskMonitor.commandFinished(connectedId, exitCode: exitCode),
        onZmodemOffer: (offer) => unawaited(_handleZmodemOffer(offer)),
        onZmodemRequest: _requestZmodemFiles,
        onCommand: (command) {
          unawaited(
            commandHistory.record(
              command: command,
              host: hops.last.host,
              username: connectedUsername,
            ),
          );
          taskMonitor.commandSubmitted(
            connectedId,
            command,
            title: '$connectedUsername@${hops.last.host}',
          );
        },
      );
      final session = _Session(
        connectedId,
        hops.last.host,
        connectedUsername,
        hops.last.hostId,
        terminal,
        profile: profile,
      );
      _bindInputRouting(session);
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

  Future<void> _handleZmodemOffer(ZModemOffer offer) async {
    if (!mounted) {
      offer.skip();
      return;
    }
    final info = offer.info;
    final rawName = info.pathname.split(RegExp(r'[/\\]')).last.trim();
    final name = rawName.isEmpty || rawName == '.' || rawName == '..'
        ? 'zmodem-file'
        : rawName;
    final size = info.length;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('接收 ZMODEM 文件'),
        content: Text(
          '远端请求发送文件：\n\n$name'
          '${size == null ? '' : '\n${_formatZmodemSize(size)}'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('跳过'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('接收'),
          ),
        ],
      ),
    );
    if (accepted != true) {
      offer.skip();
      return;
    }
    try {
      String? path;
      if (Platform.isIOS) {
        final directory = await getTemporaryDirectory();
        path =
            '${directory.path}/wterm-zmodem-${DateTime.now().microsecondsSinceEpoch}-$name';
      } else {
        final location = await getSaveLocation(suggestedName: name);
        path = location?.path;
      }
      if (path == null) {
        offer.skip();
        return;
      }
      final file = File(path);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      try {
        await for (final chunk in offer.accept(0)) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (!mounted) return;
      if (Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(path)],
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('ZMODEM 文件已保存：$path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ZMODEM 接收失败：${userFacingError(e)}')),
        );
      }
    }
  }

  String _formatZmodemSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '$bytes B';
  }

  Future<Iterable<ZModemOffer>> _requestZmodemFiles() async {
    final files = await openFiles();
    final offers = <ZModemOffer>[];
    for (final file in files) {
      final length = await file.length();
      offers.add(
        ZModemCallbackOffer(
          ZModemFileInfo(pathname: file.name, length: length),
          onAccept: (offset) => file.openRead(offset),
        ),
      );
    }
    return offers;
  }

  void _deepLinkReceived() {
    final uri = pendingDeepLink.value;
    if (uri == null || !mounted) return;
    pendingDeepLink.value = null;
    final profile = hostProfileFromDeepLink(uri);
    if (profile == null) return;
    if (connecting) {
      message('已有连接正在进行，请稍后重试深链接。');
      return;
    }
    unawaited(connect(profile));
  }

  void _trayConnectRequested() {
    if (!mounted || connecting) return;
    unawaited(connect());
  }

  Future<bool> _handleNativeMethod(MethodCall call) async {
    if (call.method != 'attachTerminalWindow') return false;
    final args = call.arguments;
    final raw = args is Map ? args['payload'] : null;
    if (raw is! String) return false;
    return _attachReturnedTerminal(raw);
  }

  Future<bool> _handleWindowRecall(MethodCall call) async {
    if (call.method != 'recall') {
      throw MissingPluginException('Unknown recall method ${call.method}');
    }
    final raw = call.arguments;
    if (raw is! String) return false;
    final accepted = await _attachReturnedTerminal(raw);
    if (accepted && mounted && Platform.isWindows) {
      unawaited(windowManager.show().catchError((Object _) {}));
      unawaited(windowManager.focus().catchError((Object _) {}));
    }
    return accepted;
  }

  Future<bool> _attachReturnedTerminal(String raw) async {
    final handoff = SessionHandoffPayload.decode(raw);
    if (handoff == null) return false;
    try {
      final connectionId = handoff.connectionId;
      final host = handoff.host;
      final username = handoff.username;
      final snapshot = handoff.snapshot;
      final existing = _sessionById(connectionId);
      if (existing != null) {
        final tab = _tabForSession(connectionId);
        if (tab != null && mounted) {
          setState(() => selected = tabs.indexOf(tab));
        }
        return true;
      }
      late final TerminalSession terminal;
      terminal = TerminalSession.attach(
        connectionId: connectionId,
        host: host,
        username: username,
        snapshot: snapshot,
        onEnded: () => _terminalEnded(connectionId),
        onActivity: () => taskMonitor.activity(connectionId),
        onCommandFinished: (exitCode) =>
            taskMonitor.commandFinished(connectionId, exitCode: exitCode),
        onZmodemOffer: (offer) => unawaited(_handleZmodemOffer(offer)),
        onZmodemRequest: _requestZmodemFiles,
        onCommand: (command) {
          unawaited(
            commandHistory.record(
              command: command,
              host: host,
              username: username,
            ),
          );
          taskMonitor.commandSubmitted(
            connectionId,
            command,
            title: username.isEmpty ? host : '$username@$host',
          );
        },
      );
      HostProfile? profile;
      if (handoff.hostId.isNotEmpty) {
        try {
          profile = (await hostStore.read())
              .where((item) => item.id == handoff.hostId)
              .firstOrNull;
        } catch (_) {
          // The host may have been deleted; keep the live session.
        }
      }
      final session = _Session(
        connectionId,
        host,
        username,
        handoff.hostId,
        terminal,
        profile: profile,
      );
      _bindInputRouting(session);
      if (!mounted) {
        terminal.dispose();
        return false;
      }
      setState(() {
        sessions.add(session);
        tabs.add(
          WorkspaceTab(
            id: HostProfile.newId(),
            root: SessionPane(session.id),
            activeSessionId: session.id,
          ),
        );
        selected = tabs.length - 1;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  void _restartAutoSync() {
    _autoSyncTimer?.cancel();
    if (!syncAutomation.enabled || hostStore is! SyncStore) return;
    _autoSyncTimer = Timer.periodic(
      Duration(minutes: syncAutomation.intervalMinutes),
      (_) => unawaited(_runAutoSync()),
    );
    unawaited(_runAutoSync());
  }

  Future<void> _runAutoSync() async {
    if (!mounted ||
        _autoSyncBusy ||
        !syncAutomation.enabled ||
        hostStore is! SyncStore) {
      return;
    }
    _autoSyncBusy = true;
    try {
      final store = hostStore as SyncStore;
      final profile = await store.syncSettings();
      if (!profile.configured ||
          !profile.initialized ||
          !profile.tokenSaved ||
          profile.pending) {
        return;
      }
      await store.runSync();
      if (!mounted) return;
      final review = await store.syncConflicts();
      if (review != null && review.items.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('自动同步发现 ${review.items.length} 项冲突，需要手动审阅'),
            action: SnackBarAction(
              label: '审阅',
              onPressed: () => unawaited(
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => SyncDialog(store: store),
                ),
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) message('自动同步失败：${userFacingError(e)}');
    } finally {
      _autoSyncBusy = false;
    }
  }

  void _taskCompleted() {
    if (!mounted) return;
    for (final completion in taskMonitor.drain()) {
      final fullCommand = completion.command;
      final command = fullCommand.length > 48
          ? '${fullCommand.substring(0, 48)}…'
          : fullCommand;
      if (pluginSettings.taskNotifications) {
        unawaited(
          systemNotifications.showTask(
            title: completion.title,
            body:
                '$fullCommand（${completion.elapsed.inSeconds} 秒'
                '${completion.exitCode == null ? '' : '，退出码 ${completion.exitCode}'}）',
          ),
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '任务完成 · ${completion.title} · $command（${completion.elapsed.inSeconds} 秒'
            '${completion.exitCode == null ? '' : '，退出码 ${completion.exitCode}'}）',
          ),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              final tab = _tabForSession(completion.sessionId);
              if (tab == null) return;
              setState(() => selected = tabs.indexOf(tab));
              _scheduleLayoutSave();
            },
          ),
        ),
      );
    }
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

  void _handleTabDrop(String source, String targetSessionId, SplitEdge edge) {
    final paneSessionId = paneDragSessionId(source);
    if (paneSessionId != null) {
      _movePaneToSplit(paneSessionId, targetSessionId, edge);
      return;
    }
    final sourceTabId = source;
    final target = _tabForSession(targetSessionId);
    if (target != null && target.id == sourceTabId) {
      // Dropping the current tab on one of its own panes means "split this
      // pane with another open session"; a tab cannot be merged with itself.
      unawaited(_splitSessionAt(targetSessionId, edge));
      return;
    }
    _dropTab(sourceTabId, targetSessionId, edge);
  }

  /// Moves a pane onto another pane's edge. Works inside one tab (drag to
  /// rearrange/resize a split) and across tabs (merge the pane into a tab).
  void _movePaneToSplit(
    String sessionId,
    String targetSessionId,
    SplitEdge edge,
  ) {
    if (sessionId == targetSessionId) return;
    final source = _tabForSession(sessionId);
    final target = _tabForSession(targetSessionId);
    if (source == null || target == null) return;
    if (source.id != target.id) {
      _moveSessionToSplit(sessionId, targetSessionId, edge);
      return;
    }
    if (sessionIdsOrdered(source.root).length <= 1) return;
    final remaining = removeSession(source.root, sessionId);
    if (remaining == null) return;
    setState(() {
      source.root = splitAt(
        remaining,
        targetSessionId,
        edge,
        SessionPane(sessionId),
      );
      source.activeSessionId = sessionId;
      selected = tabs.indexOf(source);
    });
    _scheduleLayoutSave();
  }

  /// Dissolves a split without disconnecting anything: the active pane stays
  /// in this tab and every other pane becomes its own tab.
  void _unsplitAll(WorkspaceTab tab) {
    final ids = sessionIdsOrdered(tab.root);
    if (ids.length <= 1) return;
    final keep = tab.activeSessionId;
    final active = ids.contains(keep) ? keep : ids.first;
    setState(() {
      tab.root = SessionPane(active);
      tab.activeSessionId = active;
      for (final id in ids) {
        if (id == active) continue;
        tabs.add(
          WorkspaceTab(
            id: HostProfile.newId(),
            root: SessionPane(id),
            activeSessionId: id,
          ),
        );
      }
    });
    _scheduleLayoutSave();
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
    if (session == null) return;
    if (session.terminal.isLocal) {
      message('本地终端不支持重连，请新建本地终端。');
      return;
    }
    unawaited(_reconnect(session));
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

  final List<HostProfile> _batchQueue = [];
  bool _batchConnecting = false;

  Future<void> _queueBatchConnections(List<HostProfile> profiles) async {
    _batchQueue.addAll(profiles);
    if (_batchConnecting) return;
    _batchConnecting = true;
    try {
      while (_batchQueue.isNotEmpty && mounted) {
        final next = _batchQueue.removeAt(0);
        await connect(next);
      }
    } finally {
      _batchConnecting = false;
    }
  }

  Future<void> _detachToWindow(String id) async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      message('独立终端窗口目前仅支持 macOS 和 Windows。');
      return;
    }
    final session = _sessionById(id);
    final tab = _tabForSession(id);
    if (session == null || tab == null || !session.connected) return;

    String snapshot;
    try {
      snapshot = await session.terminal.detachForHandoff();
    } catch (e) {
      message('无法转移终端：${userFacingError(e)}');
      return;
    }
    if (!mounted) {
      session.terminal.dispose();
      return;
    }

    final title = '${session.username}@${session.host}';
    final payload = jsonEncode({
      'connectionId': session.id,
      'host': session.host,
      'username': session.username,
      'hostId': session.hostId,
      'snapshot': snapshot,
      'title': title,
    });
    var opened = false;
    try {
      if (Platform.isWindows) {
        await WindowController.create(
          WindowConfiguration(arguments: payload, hiddenAtLaunch: false),
        );
        opened = true;
      } else {
        opened =
            await const MethodChannel('dev.wterm/biometrics')
                .invokeMethod<bool>('openTerminalWindow', {
                  'payload': payload,
                  'title': title,
                }) ??
            false;
      }
    } catch (e) {
      message('无法打开独立窗口：${userFacingError(e)}');
    }

    if (!opened) {
      final replacement = TerminalSession.attach(
        connectionId: session.id,
        host: session.host,
        username: session.username,
        hostId: session.hostId,
        snapshot: snapshot,
        onEnded: () => _terminalEnded(session.id),
        onActivity: () => taskMonitor.activity(session.id),
        onCommandFinished: (exitCode) =>
            taskMonitor.commandFinished(session.id, exitCode: exitCode),
        onZmodemOffer: (offer) => unawaited(_handleZmodemOffer(offer)),
        onZmodemRequest: _requestZmodemFiles,
        onCommand: (command) {
          unawaited(
            commandHistory.record(
              command: command,
              host: session.host,
              username: session.username,
            ),
          );
          taskMonitor.commandSubmitted(session.id, command, title: title);
        },
      );
      final next = _Session(
        session.id,
        session.host,
        session.username,
        session.hostId,
        replacement,
        profile: session.profile,
      );
      _bindInputRouting(next);
      setState(() {
        final index = sessions.indexOf(session);
        if (index >= 0) sessions[index] = next;
      });
      session.terminal.dispose();
      message('无法打开独立窗口，终端已保留在当前窗口。');
      return;
    }

    setState(() {
      sessions.remove(session);
      final remaining = removeSession(tab.root, id);
      if (remaining == null) {
        tabs.remove(tab);
        selected = tabs.isEmpty ? -1 : selected.clamp(0, tabs.length - 1);
      } else {
        tab.root = remaining;
        if (tab.activeSessionId == id) {
          tab.activeSessionId = firstSession(remaining)!;
        }
      }
    });
    session.terminal.dispose();
    _scheduleLayoutSave();
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
            hostId: host.id,
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
          _bindInputRouting(session);
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
    } else if (action == 'focus') {
      setState(() => focusMode = !focusMode);
    }
  }

  Future<void> _autoCheckUpdates() async {
    if (!supportsDesktopUpdates || !mounted) return;
    final info = await checkForUpdate();
    if (!mounted || info == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('发现 W Term 新版本 ${info.version}'),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: '立即更新',
          onPressed: () => unawaited(_promptUpdate(info)),
        ),
      ),
    );
  }

  Future<void> _checkUpdates() async {
    if (!supportsDesktopUpdates) {
      message('检查更新仅在桌面端可用；移动端请通过 App Store 更新。');
      return;
    }
    final info = await checkForUpdate();
    if (!mounted) return;
    if (info == null) {
      message('当前已是最新版本（$appVersion），或暂时无法连接 GitHub 更新服务。');
      return;
    }
    await _promptUpdate(info);
  }

  Future<void> _promptUpdate(UpdateInfo info) async {
    if (!mounted) return;
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
              child: Text(Platform.isWindows ? '下载并安装' : '下载并打开'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'open'),
            child: const Text('打开发布页'),
          ),
        ],
      ),
    );
    if (choice == 'download' && asset != null) {
      if (!mounted) return;
      if (Platform.isWindows) {
        final install = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('安装更新并重启？'),
            content: const Text(
              '安装程序将静默运行，W Term 会退出并在安装完成后重启。'
              '请先保存正在填写的连接或编辑内容。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('安装并重启'),
              ),
            ],
          ),
        );
        if (install != true) return;
      }
      message('正在下载 ${asset.name}…');
      try {
        final file = await downloadUpdateAsset(asset);
        final verified = await verifyUpdateDownload(file, info);
        if (!mounted) return;
        if (!verified) {
          message('安装包 SHA256 校验失败或缺少校验文件，未打开。请前往发布页手动下载。');
          return;
        }
        if (Platform.isMacOS) {
          await Process.run('open', [file.path]);
          message('安装包已下载并打开：${file.path}');
        } else if (Platform.isWindows) {
          // Launch a detached helper first, then exit: the installer must not
          // race a still-running app (which would keep file locks and fail
          // silently under /VERYSILENT). The helper waits briefly, installs,
          // and the installer's [Run] entry starts the new app.
          await Process.start(
            'powershell.exe',
            [
              '-NoProfile',
              '-NonInteractive',
              '-WindowStyle',
              'Hidden',
              '-ExecutionPolicy',
              'Bypass',
              '-Command',
              r'Start-Sleep -Seconds 2; Start-Process -FilePath $env:WTERM_UPDATE_EXE -ArgumentList @("/VERYSILENT","/SUPPRESSMSGBOXES","/CLOSEAPPLICATIONS","/RESTARTAPPLICATIONS") -Wait',
            ],
            environment: {'WTERM_UPDATE_EXE': file.path},
          );
          message('更新程序已启动，W Term 将退出并自动安装…');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          exit(0);
        }
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

  List<TerminalSession> _broadcastTargetsFor(_Session source) {
    if (broadcastScope == BroadcastScope.off) return const [];
    final tab = _tabForSession(source.id);
    if (tab == null) return const [];
    final ids = broadcastTargetIds(
      sourceId: source.id,
      scope: broadcastScope,
      tabSessionIds: sessionIdsOrdered(tab.root),
      allSessionIds: sessions.map((session) => session.id),
      connectedSessionIds: {
        for (final session in sessions)
          if (session.connected) session.id,
      },
    );
    final byId = {for (final session in sessions) session.id: session};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!.terminal,
    ];
  }

  void _bindInputRouting(_Session session) {
    session.terminal.broadcastTargets = () => _broadcastTargetsFor(session);
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
        PopupMenuItem(
          value: 'locate',
          child: _menuRow(Icons.my_location, '定位当前连接'),
        ),
        if (Platform.isMacOS || Platform.isWindows)
          PopupMenuItem(
            value: 'detach',
            child: _menuRow(Icons.open_in_new, '在新窗口打开'),
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
            child: _menuRow(Icons.close_fullscreen, '拆回当前窗格（移到新标签）'),
          ),
        if (paneCount > 1)
          PopupMenuItem(
            value: 'unsplit-all',
            child: _menuRow(Icons.dashboard_customize_outlined, '拆分所有窗格为标签'),
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
    } else if (choice == 'detach') {
      await _detachToWindow(tab.activeSessionId);
    } else if (choice == 'locate') {
      final hostId = _sessionById(tab.activeSessionId)?.hostId ?? '';
      if (hostId.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('临时终端没有对应的主机记录')));
        return;
      }
      setState(() {
        focusMode = false;
        showIdentities = false;
        sidebarCollapsed = false;
      });
      await hostPanelKey.currentState?.locateHost(hostId);
    } else if (choice == 'split') {
      await _showSplitMenu(tab, position);
    } else if (choice == 'unsplit') {
      _splitBack(tab.activeSessionId);
    } else if (choice == 'unsplit-all') {
      _unsplitAll(tab);
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
      case 'auto-sync':
        if (hostStore is SyncStore) {
          final profile = await (hostStore as SyncStore).syncSettings();
          if (!profile.configured || !profile.initialized) {
            message('请先在 GitHub 同步中完成初始化。');
            return;
          }
          await syncAutomation.setEnabled(!syncAutomation.enabled);
          _restartAutoSync();
          message(syncAutomation.enabled ? '已启用自动同步' : '已关闭自动同步');
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
      case 'temporary':
        await connect();
      case 'local-terminal':
        await openLocalTerminal();
      case 'lock':
        widget.onLock?.call();
      case 'focus':
        if (mounted) setState(() => focusMode = !focusMode);
    }
  }

  List<SettingsSection> _settingsSections() => [
    SettingsSection(
      title: '常规',
      icon: Icons.tune,
      entries: [
        SettingsEntry(
          action: 'appearance',
          title: '终端外观',
          subtitle: '配色、字体、字号与选中即复制',
          icon: Icons.palette_outlined,
        ),
        SettingsEntry(
          action: 'plugins',
          title: '插件设置',
          subtitle: 'JSON、IP 查询、文件预览、补全、通知与输入',
          icon: Icons.extension_outlined,
        ),
        SettingsEntry(
          action: 'focus',
          title: focusMode ? '退出聚焦模式' : '聚焦模式',
          subtitle: '隐藏侧栏，仅显示终端',
          icon: focusMode ? Icons.fullscreen_exit : Icons.fullscreen,
        ),
        SettingsEntry(action: 'sessions', title: '已打开终端', icon: Icons.list_alt),
        SettingsEntry(action: 'history', title: '命令历史', icon: Icons.history),
      ],
    ),
    SettingsSection(
      title: '连接与文件',
      icon: Icons.link,
      entries: [
        if (hostStore is ConnectionProxyStore)
          SettingsEntry(
            action: 'proxy',
            title: '连接代理',
            subtitle: '命名 HTTP CONNECT / SOCKS5 代理',
            icon: Icons.route_outlined,
          ),
        SettingsEntry(
          action: 'known',
          title: '服务器指纹',
          icon: Icons.verified_user_outlined,
        ),
        if (hostStore is SnippetStore)
          SettingsEntry(action: 'snippets', title: '命令片段', icon: Icons.code),
        SettingsEntry(action: 'temporary', title: '临时终端', icon: Icons.bolt),
        if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
          SettingsEntry(
            action: 'local-terminal',
            title: '本地终端',
            icon: Icons.computer,
          ),
      ],
    ),
    if (hostStore is SyncStore)
      SettingsSection(
        title: '同步',
        icon: Icons.sync,
        entries: [
          SettingsEntry(
            action: 'sync',
            title: 'GitHub 同步',
            subtitle: '私有仓库端到端加密同步',
            icon: Icons.sync,
          ),
        ],
      ),
    if (hostStore is VaultMaintenance || widget.onLock != null)
      SettingsSection(
        title: '安全',
        icon: Icons.security,
        entries: [
          if (hostStore is VaultMaintenance)
            SettingsEntry(
              action: 'vault',
              title: '保险库与备份',
              subtitle: '修改主密码、导出与恢复备份',
              icon: Icons.security_outlined,
            ),
          if (widget.onLock != null)
            SettingsEntry(
              action: 'lock',
              title: '锁定保险库',
              icon: Icons.lock_outline,
              closeOnAction: true,
            ),
        ],
      ),
    if (supportsDesktopUpdates)
      SettingsSection(
        title: '更新',
        icon: Icons.system_update,
        entries: [
          SettingsEntry(
            action: 'update',
            title: '检查更新',
            subtitle: 'GitHub Release',
            icon: Icons.system_update,
          ),
        ],
      ),
  ];

  Future<void> _openSettings(bool drawer) async {
    if (drawer) {
      scaffoldKey.currentState?.closeDrawer();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppSettingsDialog(
        sections: _settingsSections(),
        autoSyncEnabled: syncAutomation.enabled,
        showAutoSync: hostStore is SyncStore,
        version: '$appVersion ($appBuild)',
        onAutoSyncChanged: (enabled) async {
          if (hostStore is! SyncStore) return false;
          final profile = await (hostStore as SyncStore).syncSettings();
          if (!profile.configured || !profile.initialized) {
            message('请先在 GitHub 同步中完成初始化。');
            return false;
          }
          await syncAutomation.setEnabled(enabled);
          _restartAutoSync();
          return true;
        },
        onAction: (action) async {
          if (action == 'appearance') {
            await showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) =>
                  TerminalAppearanceDialog(store: terminalAppearance),
            );
          } else if (action == 'plugins') {
            await showDialog<void>(
              context: context,
              builder: (_) => const PluginSettingsDialog(),
            );
          } else {
            await sidebarAction(action, false);
          }
        },
      ),
    );
  }

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
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.tune, size: 18),
          onPressed: () => _openSettings(false),
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
                      onBatchConnect: (profiles) {
                        if (drawer) scaffoldKey.currentState?.closeDrawer();
                        unawaited(_queueBatchConnections(profiles));
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
                  IconButton(
                    tooltip: '设置',
                    icon: const Icon(Icons.tune, size: 18),
                    onPressed: () => _openSettings(drawer),
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
        onWillAcceptWithDetails: (details) =>
            paneDragSessionId(details.data) != null || details.data != tab.id,
        onAcceptWithDetails: (details) =>
            _handleTabDrop(details.data, tab.activeSessionId, SplitEdge.right),
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
    onLayoutCommitted: _scheduleLayoutSave,
    focusMode: focusMode,
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
                    if (wide && !focusMode) ...[
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
                          if (!focusMode) ...[
                            sessionBar(wide),
                            const Divider(height: 1),
                          ],
                          Expanded(
                            child: Stack(
                              children: [
                                tabs.isEmpty
                                    ? emptyState()
                                    : IndexedStack(
                                        index: selected.clamp(
                                          0,
                                          tabs.length - 1,
                                        ),
                                        children: [
                                          for (final tab in tabs) _tabView(tab),
                                        ],
                                      ),
                                if (focusMode)
                                  Positioned(
                                    top: 8,
                                    right: 12,
                                    child: Tooltip(
                                      message: '退出聚焦模式（F11）',
                                      child: Material(
                                        color: Colors.black.withValues(
                                          alpha: 0.45,
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          onTap: () =>
                                              setState(() => focusMode = false),
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 6,
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.fullscreen_exit,
                                                  size: 15,
                                                  color: Colors.white,
                                                ),
                                                SizedBox(width: 5),
                                                Text(
                                                  '聚焦模式',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
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
  final VoidCallback onLayoutCommitted;
  final bool focusMode;
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
    required this.onLayoutCommitted,
    this.focusMode = false,
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
          onLayoutCommitted: widget.onLayoutCommitted,
        );
        if (widget.focusMode) return panes;
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
                  if (!active.terminal.isLocal)
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
                  if (!active.terminal.isLocal && openedFiles && split) ...[
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
  final VoidCallback onLayoutCommitted;
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
    required this.onLayoutCommitted,
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
      broadcastTargetCount: targets.length,
      paneDragData: paneDragData(session.id),
      hostTags: session.profile?.tags ?? const [],
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
        final first = (split.fraction * 1000).round().clamp(20, 980);
        final second = 1000 - first;
        final divider = _SplitDivider(
          axis: split.axis,
          fraction: split.fraction,
          extent: extent,
          onChanged: (value) {
            split.fraction = value;
            onLayoutChanged();
          },
          onCommitted: onLayoutCommitted,
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
            onLayoutCommitted: onLayoutCommitted,
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
            onLayoutCommitted: onLayoutCommitted,
          ),
        );
        return horizontal
            ? Row(children: [firstChild, divider, secondChild])
            : Column(children: [firstChild, divider, secondChild]);
      },
    );
  }
}

class _SplitDivider extends StatefulWidget {
  final Axis axis;
  final double fraction;
  final double extent;
  final ValueChanged<double> onChanged;
  final VoidCallback onCommitted;
  const _SplitDivider({
    required this.axis,
    required this.fraction,
    required this.extent,
    required this.onChanged,
    required this.onCommitted,
  });
  @override
  State<_SplitDivider> createState() => _SplitDividerState();
}

class _SplitDividerState extends State<_SplitDivider> {
  bool hovering = false;
  double? _liveFraction;

  bool get horizontal => widget.axis == Axis.horizontal;

  double _clamp(double value) {
    final minimum = (72 / widget.extent).clamp(.02, .45);
    return value.clamp(minimum, 1 - minimum);
  }

  void _update(double delta) {
    if (widget.extent <= 0) return;
    final next = _clamp(
      (_liveFraction ?? widget.fraction) + delta / widget.extent,
    );
    setState(() => _liveFraction = next);
    widget.onChanged(next);
  }

  void _commit() {
    _liveFraction = null;
    widget.onCommitted();
  }

  @override
  Widget build(BuildContext context) {
    final active = hovering || _liveFraction != null;
    final primary = Theme.of(context).colorScheme.primary;
    final idle = Theme.of(context).colorScheme.outlineVariant;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => hovering = true),
      onExit: (_) => setState(() => hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () {
          widget.onChanged(.5);
          widget.onCommitted();
        },
        onHorizontalDragStart: horizontal ? (_) => _commitDrag() : null,
        onHorizontalDragUpdate: horizontal
            ? (details) => _update(details.delta.dx)
            : null,
        onHorizontalDragEnd: horizontal ? (_) => _commit() : null,
        onHorizontalDragCancel: horizontal ? _commit : null,
        onVerticalDragStart: horizontal ? null : (_) => _commitDrag(),
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => _update(details.delta.dy),
        onVerticalDragEnd: horizontal ? null : (_) => _commit(),
        onVerticalDragCancel: horizontal ? null : _commit,
        child: Tooltip(
          message: '拖动调整窗格大小，双击恢复均分',
          child: SizedBox(
            width: horizontal ? 8 : double.infinity,
            height: horizontal ? double.infinity : 8,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: horizontal ? (active ? 3 : 1) : double.infinity,
                height: horizontal ? double.infinity : (active ? 3 : 1),
                color: active ? primary : idle,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _commitDrag() {
    _liveFraction = null;
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
