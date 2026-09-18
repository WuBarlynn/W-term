import '../app/errors.dart';
import 'upload_conflict_dialog.dart';

import 'package:desktop_drop/desktop_drop.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../app/temporary_directory.dart';

import 'package:share_plus/share_plus.dart';

import '../src/rust/api/client.dart' as native;

class FilesPane extends StatefulWidget {
  final String connectionId;
  final bool dropActive;
  const FilesPane({
    super.key,
    required this.connectionId,
    this.dropActive = true,
  });
  @override
  State<FilesPane> createState() => _FilesPaneState();
}

class _FilesPaneState extends State<FilesPane> {
  native.DirectoryListing? listing;
  String? error;
  bool busy = false, dragging = false;
  String activity = '';
  final path = TextEditingController(text: '.');
  @override
  void initState() {
    super.initState();
    load('.');
  }

  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> load(String target) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      activity = '读取目录…';
    });
    try {
      final result = await native.listDirectory(
        connectionId: widget.connectionId,
        path: target,
      );
      if (mounted) {
        setState(() {
          listing = result;
          path.text = result.path;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> nameDialog(String title, String initial) async {
    final input = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // Dialog dismissal transition can still use the controller until next frame.
    Future<void>.delayed(const Duration(milliseconds: 350), input.dispose);
    if (value == null) return null;
    if (value.trim().isEmpty ||
        value.contains('/') ||
        value.contains('\x00') ||
        value == '.' ||
        value == '..') {
      if (mounted) setState(() => error = '请输入不含 / 的有效名称');
      return null;
    }
    return value;
  }

  String remote(String name) =>
      '${listing!.path == '/' ? '' : listing!.path}/$name';
  Future<void> upload() async {
    if (listing == null || busy) return;
    final destination = listing!.path;
    setState(() {
      busy = true;
      error = null;
      activity = '选择上传文件…';
    });
    try {
      final files = await openFiles();
      if (!mounted) return;
      setState(() => busy = false);
      await uploadFiles(files, destination: destination);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = userFacingError(e);
        });
      }
    }
  }

  Future<void> uploadFiles(List<XFile> files, {String? destination}) async {
    if (listing == null || busy || files.isEmpty) return;
    final directory = destination ?? listing!.path;
    setState(() {
      busy = true;
      dragging = false;
      error = null;
    });
    var uploaded = 0;
    var cancelled = false;
    final failures = <String>[];
    try {
      for (final file in files) {
        if (!mounted) break;
        Directory? temporary;
        var scoped = false;
        final bookmark = file is DropItem ? file.extraAppleBookmark : null;
        try {
          final name = file.name;
          if (name.isEmpty ||
              name.contains('/') ||
              name.contains('\x00') ||
              name == '.' ||
              name == '..') {
            throw const FormatException('无效的文件名');
          }
          setState(
            () => activity = '上传 $name（${uploaded + 1}/${files.length}）…',
          );
          if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
            scoped = await DesktopDrop.instance
                .startAccessingSecurityScopedResource(bookmark: bookmark);
            if (!scoped) {
              throw const FileSystemException('无法获得拖入文件的访问权限，请使用上传按钮选择文件');
            }
          }
          if (await FileSystemEntity.type(file.path) !=
              FileSystemEntityType.file) {
            throw const FormatException('当前支持上传文件；文件夹递归上传尚未实现');
          }
          temporary = await createAppTemporaryDirectory('wterm-upload-');
          final local = File('${temporary.path}/payload');
          await file.openRead().cast<List<int>>().pipe(local.openWrite());
          if (!mounted) break;
          var policy = 'reject';
          while (mounted) {
            try {
              final result = await native.uploadFileWithPolicy(
                connectionId: widget.connectionId,
                localPath: local.path,
                remotePath: '${directory == '/' ? '' : directory}/$name',
                policy: policy,
              );
              uploaded++;
              if (mounted) {
                setState(
                  () => activity =
                      '已上传 ${result.remotePath.split('/').last} · ${formatSize(result.bytes)}',
                );
              }
              break;
            } catch (e) {
              if (!e.toString().contains('Destination already exists') ||
                  !mounted) {
                rethrow;
              }
              final choice = await chooseUploadConflict(context, name);
              if (choice == null) {
                cancelled = true;
                break;
              }
              policy = choice;
            }
          }
        } catch (e) {
          failures.add('${file.name}：${userFacingError(e)}');
        } finally {
          if (scoped && bookmark != null) {
            try {
              await DesktopDrop.instance.stopAccessingSecurityScopedResource(
                bookmark: bookmark,
              );
            } catch (_) {
              /* Transfer result remains visible. */
            }
          }
          if (temporary != null) {
            try {
              await temporary.delete(recursive: true);
            } on FileSystemException {
              /* OS cleanup may have removed it. */
            }
          }
        }
        if (cancelled) break;
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await load(directory);
        if (mounted) {
          setState(() {
            if (failures.isNotEmpty) error = failures.join('\n');
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '已上传 $uploaded 个文件${cancelled ? '，已取消剩余上传' : ''}${failures.isEmpty ? '' : '，${failures.length} 个失败'}',
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> download(native.RemoteEntry entry) async {
    Directory? temporary;
    try {
      setState(() {
        busy = true;
        error = null;
        activity = '下载 ${entry.name}…';
      });
      temporary = await createAppTemporaryDirectory('wterm-download-');
      // Remote names are never used as local paths.
      final local = '${temporary.path}/download';
      final count = await native.downloadFile(
        connectionId: widget.connectionId,
        remotePath: entry.path,
        localPath: local,
      );
      if (!mounted) return;
      if (Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(local)],
            fileNameOverrides: [entry.name],
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final destination = await getSaveLocation(suggestedName: entry.name);
        if (destination != null) await XFile(local).saveTo(destination.path);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载完成 · ${formatSize(count)}')));
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (temporary != null) await temporary.delete(recursive: true);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> preview(native.RemoteEntry entry) async {
    setState(() {
      busy = true;
      error = null;
      activity = '读取预览…';
    });
    try {
      final text = await native.previewText(
        connectionId: widget.connectionId,
        path: entry.path,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(entry.name),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
              ),
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
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> mkdir() async {
    final name = await nameDialog('新建文件夹', '');
    if (name == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      activity = '创建文件夹…';
    });
    try {
      await native.createDirectory(
        connectionId: widget.connectionId,
        path: remote(name),
      );
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (error == null) await load(listing!.path);
      }
    }
  }

  void setDragging(bool value) {
    Future.microtask(() {
      if (mounted) setState(() => dragging = value);
    });
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    enable:
        Platform.isMacOS &&
        widget.dropActive &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        !busy &&
        listing != null,
    onDragEntered: (_) => setDragging(true),
    onDragExited: (_) => setDragging(false),
    onDragDone: (details) {
      if (widget.dropActive && (ModalRoute.of(context)?.isCurrent ?? true)) {
        uploadFiles(details.files);
      }
    },
    child: Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '上级目录',
                    onPressed: busy || listing == null
                        ? null
                        : () => load(remote('..')),
                    icon: const Icon(Icons.arrow_upward, size: 19),
                  ),
                  Expanded(
                    child: TextField(
                      controller: path,
                      enabled: !busy,
                      style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.folder_outlined, size: 18),
                      ),
                      onSubmitted: load,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: busy ? null : () => load(path.text),
                    icon: const Icon(Icons.refresh, size: 19),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Text(
                    '${listing?.entries.length ?? 0} 个项目',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '新建文件夹',
                    onPressed: busy || listing == null ? null : mkdir,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 19,
                    ),
                  ),
                  IconButton(
                    tooltip: '上传文件',
                    onPressed: busy || listing == null ? null : upload,
                    icon: const Icon(Icons.upload_outlined, size: 19),
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            if (busy)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  activity,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: listing == null
                  ? Center(child: Text(busy ? '连接 SFTP…' : '无法读取目录'))
                  : listing!.entries.isEmpty
                  ? const Center(child: Text('此文件夹为空'))
                  : ListView.builder(
                      itemCount: listing!.entries.length,
                      itemBuilder: (context, index) {
                        final entry = listing!.entries[index];
                        return ListTile(
                          dense: true,
                          enabled: !busy,
                          leading: Icon(
                            entry.isDirectory
                                ? Icons.folder_outlined
                                : entry.isSymlink
                                ? Icons.link
                                : Icons.insert_drive_file_outlined,
                            size: 21,
                            color: entry.isDirectory
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: entry.isDirectory
                              ? null
                              : Text(
                                  formatSize(entry.size),
                                  style: const TextStyle(fontSize: 11),
                                ),
                          onTap: () => entry.isDirectory
                              ? load(entry.path)
                              : preview(entry),
                          trailing: entry.isDirectory
                              ? const Icon(Icons.chevron_right, size: 16)
                              : IconButton(
                                  tooltip: '下载',
                                  onPressed: busy
                                      ? null
                                      : () => download(entry),
                                  icon: const Icon(
                                    Icons.download_outlined,
                                    size: 18,
                                  ),
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
        if (dragging && widget.dropActive && !busy)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Theme.of(context).colorScheme.primaryContainer
                    .withValues(alpha: .93),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Text(
                  '松开上传到\n${listing?.path ?? ""}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
