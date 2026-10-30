import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/host_import.dart';
import '../app/host_store.dart';
import '../app/host_icons.dart';
import '../app/errors.dart';
import '../app/identity_store.dart';
import '../app/proxy_store.dart';
import '../src/rust/api/proxy.dart' show ProxyProfile;
import 'host_editor.dart';
import 'openssh_import_dialog.dart';
import 'host_csv_import_dialog.dart';

class HostsPage extends StatefulWidget {
  final HostStore store;
  final bool embedded;
  final ValueChanged<HostProfile>? onConnect;
  final ValueChanged<List<HostProfile>>? onBatchConnect;
  const HostsPage({
    super.key,
    required this.store,
    this.embedded = false,
    this.onConnect,
    this.onBatchConnect,
  });
  @override
  State<HostsPage> createState() => HostsPageState();
}

class HostsPageState extends State<HostsPage> {
  List<HostProfile> hosts = [];
  bool loading = true, saving = false, favorites = false;
  String query = '';
  List<String> folders = [];
  final collapsed = <String>{};
  String? error;
  String? selectedHostId, hoveredHostId, anchorHostId;
  final selectedIds = <String>{};
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.store.read();
      final store = widget.store;
      final savedFolders = store is FolderStore
          ? await (store as FolderStore).readFolders()
          : <String>[];
      if (mounted) {
        setState(() {
          hosts = result;
          folders = savedFolders;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '无法读取主机配置：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> importCsv() async {
    final bundle = await showDialog<HostImportBundle>(
      context: context,
      builder: (_) => const HostCsvImportDialog(),
    );
    if (bundle == null || bundle.hosts.isEmpty || !mounted) return;
    if (widget.store is IdentityStore) {
      final identityStore = widget.store as IdentityStore;
      var saved = 0, savedPasswords = 0, failed = 0;
      for (final host in bundle.hosts) {
        final password = bundle.passwords[host.id];
        try {
          await identityStore.saveHost(
            host,
            password == null
                ? null
                : IdentityDraft(
                    name: '导入 · ${host.name}',
                    username: host.username,
                    kind: 'password',
                    password: password,
                  ),
          );
          saved++;
          if (password != null) savedPasswords++;
        } catch (_) {
          failed++;
        }
      }
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导入 $saved 台主机'
              '${savedPasswords == 0 ? '' : '，$savedPasswords 个密码已存入身份库'}'
              '${failed == 0 ? '' : '，$failed 台失败'}',
            ),
          ),
        );
      }
      return;
    }
    await persist([...hosts, ...bundle.hosts]);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入 ${bundle.hosts.length} 台主机')));
    }
  }

  Future<void> editWiki(HostProfile host) async {
    final controller = TextEditingController(text: host.wiki);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('服务器 Wiki · ${host.name}'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 8,
            maxLines: 14,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: '记录部署说明、注意事项、常用命令…',
              helperText: '纯文本 / Markdown，随主机配置保存',
              alignLabelWithHint: true,
            ),
          ),
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
    if (value == null || !mounted) return;
    if (utf8.encode(value).length > 64 * 1024) {
      setState(() => error = '服务器 Wiki 不能超过 64 KiB');
      return;
    }
    await persist(
      hosts
          .map((item) => item.id == host.id ? item.withWiki(value) : item)
          .toList(),
    );
  }

  Future<void> persist(List<HostProfile> next) async {
    setState(() => saving = true);
    try {
      await widget.store.write(next);
      if (mounted) {
        setState(() {
          hosts = next;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：${userFacingError(e)}')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> edit([HostProfile? profile, String initialGroup = '']) async {
    final proxyStore = widget.store is ConnectionProxyStore
        ? widget.store as ConnectionProxyStore
        : null;
    var proxyProfiles = const <ProxyProfile>[];
    var proxyBinding = '';
    if (proxyStore != null) {
      try {
        proxyProfiles = await proxyStore.proxyProfiles();
        if (profile != null) {
          proxyBinding = await proxyStore.hostProxyBinding(profile.id);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('无法读取代理设置：${userFacingError(e)}')),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    final result = await showDialog<HostProfile>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HostEditor(
        profile: profile,
        credentials: widget.store is IdentityStore
            ? widget.store as IdentityStore
            : null,
        initialGroup: initialGroup,
        candidates: hosts,
        proxies: proxyStore,
        proxyProfiles: proxyProfiles,
        proxyBinding: proxyBinding,
        folders: {
          ...folders,
          ...hosts.map((h) => h.group),
        }.where((f) => f.isNotEmpty).toList(),
      ),
    );
    if (result == null || !mounted) return;
    if (widget.store is IdentityStore) {
      await load();
    } else {
      await persist([...hosts.where((h) => h.id != result.id), result]);
    }
  }

  Future<void> importConfig() async {
    final count = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OpenSshImportDialog(store: widget.store),
    );
    if (!mounted || count == null) return;
    await load();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导入 $count 台主机，相同配置已跳过')));
    }
  }

  Future<void> remove(HostProfile profile) async {
    final dependents = hosts
        .where((h) => h.id != profile.id && h.jumpHostIds.contains(profile.id))
        .toList();
    if (dependents.isNotEmpty) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('不能删除此跳板主机'),
            content: Text(
              '以下主机的跳板路线仍引用“${profile.name}”：\n\n'
              '${dependents.map((h) => '· ${h.name}').join('\n')}\n\n'
              '请先编辑这些主机并移除该跳板。',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${profile.name}”？'),
        content: const Text('仅删除保存的主机配置。正在运行的会话和已验证的服务器指纹仍会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await persist(hosts.where((h) => h.id != profile.id).toList());
    }
  }

  Future<void> addFolder([String parent = '']) async {
    var folderName = '';
    final form = GlobalKey<FormState>();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(parent.isEmpty ? '新建文件夹' : '新建子文件夹'),
        content: Form(
          key: form,
          child: TextFormField(
            onChanged: (v) => folderName = v,
            autofocus: true,
            decoration: const InputDecoration(labelText: '文件夹名称'),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return '请输入名称';
              if (v.contains('/') || v.trim() == '.' || v.trim() == '..') {
                return '名称不能包含 / 或为 .、..';
              }
              final path = parent.isEmpty ? v.trim() : '$parent/${v.trim()}';
              if (path.split('/').length > 16) return '最多支持 16 层文件夹';
              return {...folders, ...hosts.map((h) => h.group)}.contains(path)
                  ? '文件夹已存在'
                  : null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  context,
                  parent.isEmpty
                      ? folderName.trim()
                      : '$parent/${folderName.trim()}',
                );
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final store = widget.store;
    if (store is! FolderStore) return;
    setState(() => saving = true);
    try {
      final next = [...folders, name];
      await (store as FolderStore).writeFolders(next);
      if (mounted) setState(() => folders = next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：${userFacingError(e)}')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> renameFolder(String path) async {
    final store = widget.store;
    if (store is! FolderTreeStore || saving) return;
    var name = path.split('/').last;
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名文件夹'),
        content: Form(
          key: form,
          child: TextFormField(
            initialValue: name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '文件夹名称',
              helperText: '子文件夹和主机归属会一起更新',
            ),
            onChanged: (v) => name = v,
            validator: (v) =>
                v == null ||
                    v.trim().isEmpty ||
                    v.trim() == '.' ||
                    v.trim() == '..' ||
                    v.contains('/') ||
                    RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)
                ? '请输入不含 / 或控制字符的有效名称'
                : null,
            onFieldSubmitted: (_) {
              if (form.currentState!.validate()) Navigator.pop(c, name.trim());
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, name.trim());
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    setState(() => saving = true);
    try {
      final destination = await (store as FolderTreeStore).renameFolder(
        path,
        result,
      );
      if (!mounted) return;
      final nextCollapsed = collapsed
          .map(
            (p) => p == path || p.startsWith('$path/')
                ? '$destination${p.substring(path.length)}'
                : p,
          )
          .toSet();
      collapsed
        ..clear()
        ..addAll(nextCollapsed);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> deleteFolder(String path) async {
    final store = widget.store;
    if (store is! FolderTreeStore) return;
    final deleteHosts = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除文件夹“$path”？'),
        content: const Text('包含所有子文件夹。请选择如何处理其中的全部主机；保存的身份与密钥仍保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('保留主机到未分类'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除文件夹及全部主机'),
          ),
        ],
      ),
    );
    if (deleteHosts == null || !mounted) return;
    setState(() => saving = true);
    try {
      await (store as FolderTreeStore).deleteFolder(
        path,
        deleteHosts: deleteHosts,
      );
      collapsed.removeWhere((p) => p == path || p.startsWith('$path/'));
      await load();
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> locateHost(String hostId) async {
    if (!hosts.any((host) => host.id == hostId)) await load();
    final matches = hosts.where((host) => host.id == hostId);
    if (matches.isNotEmpty && mounted) selectHost(matches.first);
  }

  void selectHost(HostProfile h) {
    final keyboard = HardwareKeyboard.instance;
    setState(() {
      selectedHostId = h.id;
      if (keyboard.isShiftPressed && anchorHostId != null) {
        final anchor = hosts.indexWhere((item) => item.id == anchorHostId);
        final target = hosts.indexWhere((item) => item.id == h.id);
        if (anchor >= 0 && target >= 0) {
          final start = anchor < target ? anchor : target;
          final end = anchor < target ? target : anchor;
          selectedIds.addAll(hosts.sublist(start, end + 1).map((i) => i.id));
        }
      } else if (keyboard.isMetaPressed || keyboard.isControlPressed) {
        if (!selectedIds.remove(h.id)) selectedIds.add(h.id);
        anchorHostId = h.id;
      } else {
        selectedIds
          ..clear()
          ..add(h.id);
        anchorHostId = h.id;
      }
    });
  }

  Future<void> batchFavorite(bool value) async {
    final ids = Set<String>.of(selectedIds);
    if (ids.isEmpty) return;
    await persist(
      hosts.map((h) => ids.contains(h.id) ? h.withFavorite(value) : h).toList(),
    );
    if (mounted) setState(selectedIds.clear);
  }

  Future<void> batchDelete() async {
    final ids = Set<String>.of(selectedIds);
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除选中的 ${ids.length} 台主机？'),
        content: const Text('正在运行的会话和已验证的服务器指纹仍会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await persist(hosts.where((h) => !ids.contains(h.id)).toList());
    if (mounted) setState(selectedIds.clear);
  }

  void connectHost(HostProfile h) {
    if (widget.onConnect != null) {
      widget.onConnect!(h);
    } else {
      Navigator.pop(context, h);
    }
  }

  IconData hostIcon(String icon) => hostIconFor(icon);

  Widget hostTile(HostProfile h, int depth) => MouseRegion(
    onEnter: (_) => setState(() => hoveredHostId = h.id),
    onExit: (_) {
      if (hoveredHostId == h.id) setState(() => hoveredHostId = null);
    },
    child: Material(
      key: ValueKey('host-row-${h.id}'),
      color: selectedIds.contains(h.id)
          ? Theme.of(context).colorScheme.primaryContainer
          : hoveredHostId == h.id && !saving
          ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .08)
          : Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: saving ? null : () => selectHost(h),
              onDoubleTap: saving
                  ? null
                  : () {
                      selectHost(h);
                      connectHost(h);
                    },
              child: ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.only(
                  left: 40 + depth * 12.0,
                  right: 0,
                ),
                minLeadingWidth: 16,
                horizontalTitleGap: 8,
                leading: h.favorite
                    ? Icon(
                        Icons.star_rounded,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : hostIconWidget(h.icon, size: 16),
                title: Text(
                  h.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '${h.username}@${h.host}:${h.port}'
                  '${h.jumpHostIds.isEmpty ? '' : ' · ${h.jumpHostIds.length} 台跳板'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '主机操作：${h.name}',
            onOpened: () => setState(() => selectedHostId = h.id),
            enabled: !saving,
            iconSize: 17,
            onSelected: (v) {
              if (v == 'connect') {
                connectHost(h);
              } else if (v == 'favorite') {
                persist(
                  hosts
                      .map((p) => p.id == h.id ? h.toggleFavorite() : p)
                      .toList(),
                );
              } else if (v == 'edit') {
                edit(h);
              } else if (v == 'wiki') {
                editWiki(h);
              } else {
                remove(h);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'connect', child: Text('连接')),
              PopupMenuItem(
                value: 'favorite',
                child: Text(h.favorite ? '取消收藏' : '收藏主机'),
              ),
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              const PopupMenuItem(value: 'wiki', child: Text('服务器 Wiki')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    ),
  );

  List<Widget> tree(List<HostProfile> visible, bool ready) {
    final paths = <String>{};
    for (final path in {...folders, ...hosts.map((h) => h.group)}) {
      if (path.isEmpty) {
        paths.add('');
        continue;
      }
      final parts = path.split('/');
      for (var i = 1; i <= parts.length; i++) {
        paths.add(parts.take(i).join('/'));
      }
    }
    final all = paths.toList()..sort();
    final filtered = query.isNotEmpty || favorites;
    bool within(String group, String path) =>
        group == path || (path.isNotEmpty && group.startsWith('$path/'));
    final widgets = <Widget>[];
    void node(String path, int depth) {
      final matches = visible.where((h) => within(h.group, path)).toList();
      if (filtered && matches.isEmpty) return;
      final open = !collapsed.contains(path) || filtered;
      widgets.add(
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.only(left: 8 + depth * 12.0, right: 0),
          minLeadingWidth: 12,
          horizontalTitleGap: 4,
          leading: Icon(
            open ? Icons.expand_more : Icons.chevron_right,
            size: 16,
          ),
          title: Tooltip(
            message: path.isEmpty ? '未分类' : path,
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 16),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    path.isEmpty ? '未分类' : path.split('/').last,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text('${matches.length}', style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '文件夹操作：${path.isEmpty ? "未分类" : path}',
            enabled: ready,
            iconSize: 16,
            onSelected: (v) {
              if (v == 'host') {
                edit(null, path);
              } else if (v == 'folder') {
                addFolder(path);
              } else if (v == 'rename') {
                renameFolder(path);
              } else {
                deleteFolder(path);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'host', child: Text('添加主机')),
              if (widget.store is FolderStore)
                const PopupMenuItem(value: 'folder', child: Text('新建子文件夹')),
              if (path.isNotEmpty && widget.store is FolderTreeStore)
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
              if (path.isNotEmpty && widget.store is FolderTreeStore)
                const PopupMenuItem(value: 'delete', child: Text('删除文件夹')),
            ],
          ),
          onTap: () => setState(() {
            if (!collapsed.remove(path)) collapsed.add(path);
          }),
        ),
      );
      if (!open) return;
      widgets.addAll(
        visible.where((h) => h.group == path).map((h) => hostTile(h, depth)),
      );
      if (path.isNotEmpty) {
        for (final child in all.where(
          (p) =>
              p.startsWith('$path/') &&
              !p.substring(path.length + 1).contains('/'),
        )) {
          node(child, depth + 1);
        }
      }
    }

    for (final root in all.where((p) => !p.contains('/'))) {
      node(root, 0);
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final visible =
        hosts
            .where((h) => h.matches(query) && (!favorites || h.favorite))
            .toList()
          ..sort((a, b) {
            final f = (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0);
            return f != 0 ? f : a.name.compareTo(b.name);
          });
    final groups = {...folders, ...hosts.map((h) => h.group)}.toList()..sort();
    final ready = !loading && !saving && error == null;
    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '主机',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: '从其他平台导入',
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                onPressed: ready ? importCsv : null,
              ),
              IconButton(
                tooltip: '导入 OpenSSH 配置',
                icon: const Icon(Icons.file_open_outlined, size: 18),
                onPressed: ready ? importConfig : null,
              ),
              IconButton(
                tooltip: '新建文件夹',
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                onPressed: ready && widget.store is FolderStore
                    ? () => addFolder()
                    : null,
              ),
              IconButton(
                tooltip: '添加主机',
                icon: const Icon(Icons.add, size: 20),
                onPressed: ready ? () => edit() : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: '搜索主机、标签',
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (v) => setState(() => query = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              FilterChip(
                label: const Text('收藏', style: TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                selected: favorites,
                onSelected: (v) => setState(() => favorites = v),
              ),
              const Spacer(),
              Text(
                '${visible.length} 台主机',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        if (selectedIds.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                Text(
                  '已选 ${selectedIds.length} 台',
                  style: const TextStyle(fontSize: 11),
                ),
                const Spacer(),
                if (widget.onBatchConnect != null)
                  TextButton(
                    onPressed: ready
                        ? () {
                            final selected = hosts
                                .where((host) => selectedIds.contains(host.id))
                                .toList();
                            if (selected.isEmpty) return;
                            widget.onBatchConnect!(selected);
                            setState(selectedIds.clear);
                          }
                        : null,
                    child: const Text('连接'),
                  ),
                TextButton(
                  onPressed: ready ? () => batchFavorite(true) : null,
                  child: const Text('收藏'),
                ),
                TextButton(
                  onPressed: ready ? () => batchFavorite(false) : null,
                  child: const Text('取消收藏'),
                ),
                TextButton(
                  onPressed: ready ? batchDelete : null,
                  child: const Text('删除'),
                ),
                IconButton(
                  tooltip: '清除选择',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(selectedIds.clear),
                ),
              ],
            ),
          ),
        if (saving) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(error!),
                        TextButton(onPressed: load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : ListView(
                  children: [
                    if (groups.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          '添加主机或文件夹，整理你的服务器。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    if (visible.isEmpty && (query.isNotEmpty || favorites))
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('没有匹配的主机'),
                      ),
                    ...tree(visible, ready),
                  ],
                ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('主机管理')),
        body: body,
      ),
    );
  }
}
