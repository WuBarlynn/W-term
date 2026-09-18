import 'errors.dart';
import 'app_version_label.dart';
import 'host_store.dart';
import 'identity_store.dart';
import '../features/host_editor.dart';
import '../features/identities_pane.dart';
import '../features/vault_settings.dart';
import '../features/hosts_page.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/connect_dialog.dart';
import '../features/files_pane.dart';
import '../features/terminal_pane.dart';
import '../src/rust/api/client.dart' as native;
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
  final String id, host, username;
  bool connected = true;
  _Session(this.id, this.host, this.username);
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  late final TrustStore trust = widget.trustStore ?? KeychainTrustStore();
  late final HostStore hostStore = widget.hostStore ?? KeychainHostStore();
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final hostPanelKey = GlobalKey<HostsPageState>();
  bool showIdentities = false;
  final sessions = <_Session>[];
  int selected = -1, attempt = 0;
  bool connecting = false, preparing = false;
  String status = '';
  String? pending;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    attempt++;
    if (pending != null) {
      unawaited(
        native.disconnect(connectionId: pending!).catchError((Object _) {}),
      );
    }
    for (final s in sessions) {
      unawaited(
        native.disconnect(connectionId: s.id).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && Platform.isIOS) {
      cancelConnect();
      // Preview policy: close on background; do not promise an alive socket.
      for (final session in sessions) {
        unawaited(
          native.disconnect(connectionId: session.id).catchError((Object _) {}),
        );
      }
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
    final id = pending;
    pending = null;
    if (id != null) {
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
      profile = await showDialog<HostProfile>(
        context: context,
        barrierDismissible: false,
        builder: (_) => HostEditor(profile: profile, credentials: credentials),
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
      if (credentials != null) {
        final host = HostProfile(
          id: profile?.id ?? HostProfile.newId(),
          name: profile?.name ?? request.host,
          host: request.host,
          port: request.port,
          username: request.username,
          group: profile?.group ?? '',
          tags: profile?.tags ?? [],
          favorite: profile?.favorite ?? false,
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

  Future<void> connect([HostProfile? profile]) async {
    if (connecting) return;
    final currentAttempt = ++attempt;
    bool active() => mounted && currentAttempt == attempt;
    setState(() {
      connecting = true;
      preparing = true;
      status = '准备连接…';
    });
    String? id;
    ConnectionRequest? cleanup;
    bool handedOff = false;
    try {
      final prepared = await prepareConnection(profile);
      if (prepared == null) return;
      final (request, savedIdentityId) = prepared;
      cleanup = request;
      if (!active()) return;
      setState(() {
        preparing = false;
        status = '正在与 ${request.host} 建立连接…';
      });
      final identity = await native.probeServer(
        host: request.host,
        port: request.port,
      );
      id = identity.connectionId;
      if (!mounted || !active()) return;
      pending = id;
      final endpoint = endpointKey(request.host, request.port);
      final known = (await trust.read())[endpoint];
      if (!mounted || !active()) return;
      if (known != null && known != identity.fingerprint) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('服务器指纹发生变化'),
            content: SelectableText(
              '已阻止认证，未发送密码或私钥签名。\n请先向服务器管理员核实。\n\n$endpoint\n\n原指纹\n$known\n\n当前指纹\n${identity.fingerprint}',
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
            title: const Text('验证服务器身份'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('首次连接 $endpoint，请通过可信渠道核对 SHA256 指纹。'),
                  const SizedBox(height: 20),
                  SelectableText(
                    identity.fingerprint,
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '确认后，指纹将保存在此设备的钥匙串中。',
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
                child: const Text('信任并连接'),
              ),
            ],
          ),
        );
        if (allow != true || !active()) return;
        await trust.remember(endpoint, identity.fingerprint);
      }
      if (!mounted || !active()) return;
      setState(() => status = '正在认证 ${request.username}@${request.host}…');
      final String connectedUsername;
      if (savedIdentityId.isNotEmpty && hostStore is IdentityStore) {
        connectedUsername = await (hostStore as IdentityStore)
            .authenticateIdentity(savedIdentityId, id, identity.fingerprint);
      } else {
        await native.authenticate(
          connectionId: id,
          approvedFingerprint: identity.fingerprint,
          username: request.username,
          password: request.password,
          privateKey: request.privateKey,
          passphrase: request.passphrase,
        );
        connectedUsername = request.username;
      }
      if (!mounted || !active()) return;
      setState(() {
        sessions.add(_Session(id!, request.host, connectedUsername));
        selected = sessions.length - 1;
      });
      handedOff = true;
    } catch (e) {
      if (active()) message('连接失败：${userFacingError(e)}');
    } finally {
      cleanup?.clearSecrets();
      if (!handedOff && id != null) {
        await native.disconnect(connectionId: id).catchError((Object _) {});
      }
      if (active()) {
        setState(() {
          connecting = false;
          preparing = false;
          status = '';
          pending = null;
        });
      }
    }
  }

  Future<void> closeSession(int index) async {
    final session = sessions[index];
    if (session.connected) {
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('断开此会话？'),
          content: const Text('当前终端和文件传输将结束。需要保留远端工作时，请先使用 tmux。'),
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
    await native.disconnect(connectionId: session.id);
    if (!mounted) return;
    setState(() {
      final active = selected >= 0 ? sessions[selected] : null;
      sessions.remove(session);
      selected = sessions.isEmpty
          ? -1
          : active != null && sessions.contains(active)
          ? sessions.indexOf(active)
          : index.clamp(0, sessions.length - 1);
    });
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

  Widget sidebar({bool drawer = false}) => SizedBox(
    width: 272,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(
            children: [
              Icon(Icons.terminal, size: 22),
              SizedBox(width: 10),
              Text(
                'W Term',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
              ? IdentitiesPane(store: hostStore as IdentityStore)
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
        const Padding(padding: EdgeInsets.all(8), child: AppVersionLabel()),
        if (hostStore is VaultMaintenance)
          ListTile(
            dense: true,
            leading: const Icon(Icons.security_outlined, size: 17),
            title: const Text('保险库与备份', style: TextStyle(fontSize: 12)),
            onTap: () async {
              await showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    VaultSettings(store: hostStore as VaultMaintenance),
              );
              if (mounted) await hostPanelKey.currentState?.load();
            },
          ),
        if (widget.onLock != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.lock_outline, size: 17),
            title: const Text('锁定保险库', style: TextStyle(fontSize: 12)),
            subtitle: const Text('断开会话并锁定', style: TextStyle(fontSize: 10)),
            onTap: widget.onLock,
          ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.verified_user_outlined, size: 17),
          title: const Text('服务器指纹', style: TextStyle(fontSize: 12)),
          onTap: showKnownHosts,
        ),
      ],
    ),
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
          child: sessions.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Text('工作区', style: TextStyle(fontSize: 12)),
                )
              : ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (int i = 0; i < sessions.length; i++)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(3, 3, 0, 3),
                        child: Material(
                          color: selected == i
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () => setState(() => selected = i),
                                child: Tooltip(
                                  message:
                                      '${sessions[i].username}@${sessions[i].host}',
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      maxWidth: 160,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    alignment: Alignment.center,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.circle,
                                          size: 6,
                                          color: sessions[i].connected
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                              : Colors.grey,
                                        ),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: Text(
                                            sessions[i].host,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭会话',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: BoxConstraints.tightFor(
                                  width: wide ? 28 : 40,
                                  height: wide ? 28 : 38,
                                ),
                                icon: const Icon(Icons.close, size: 14),
                                onPressed: () => closeSession(i),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
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
                    if (wide) ...[sidebar(), const VerticalDivider(width: 1)],
                    Expanded(
                      child: Column(
                        children: [
                          sessionBar(wide),
                          const Divider(height: 1),
                          Expanded(
                            child: sessions.isEmpty
                                ? emptyState()
                                : IndexedStack(
                                    index: selected,
                                    children: [
                                      for (final s in sessions)
                                        _SessionView(
                                          key: ValueKey(s.id),
                                          session: s,
                                          active:
                                              selected >= 0 &&
                                              sessions[selected] == s,
                                          onDisconnected: () {
                                            if (mounted) {
                                              setState(
                                                () => s.connected = false,
                                              );
                                            }
                                          },
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

class _SessionView extends StatefulWidget {
  final _Session session;
  final bool active;
  final VoidCallback onDisconnected;
  const _SessionView({
    super.key,
    required this.session,
    required this.active,
    required this.onDisconnected,
  });
  @override
  State<_SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<_SessionView> {
  bool files = false, openedFiles = false;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final split = size.maxWidth >= 850;
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
                    '${widget.session.username}@${widget.session.host}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
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
                      Offstage(
                        offstage: files && !split,
                        child: TerminalPane(
                          connectionId: widget.session.id,
                          onDisconnected: widget.onDisconnected,
                        ),
                      ),
                      if (openedFiles && !split)
                        Offstage(
                          offstage: !files,
                          child: FilesPane(
                            connectionId: widget.session.id,
                            dropActive:
                                widget.active &&
                                files &&
                                widget.session.connected,
                          ),
                        ),
                    ],
                  ),
                ),
                if (openedFiles && split)
                  Offstage(
                    offstage: !files,
                    child: SizedBox(
                      width: 340,
                      child: FilesPane(
                        connectionId: widget.session.id,
                        dropActive:
                            widget.active && files && widget.session.connected,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
