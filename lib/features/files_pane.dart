import '../app/errors.dart';
import '../app/directory_history.dart';
import 'directory_history_bar.dart';
import '../app/upload_conflict.dart';
import '../app/folder_upload.dart';
import 'folder_upload_preview.dart';
import '../app/folder_access.dart';
import '../app/download_task.dart';
import 'download_task_dialog.dart';
import '../app/upload_batch.dart';
import 'upload_tasks_dialog.dart';
import 'upload_conflict_dialog.dart';
import 'remote_entry_actions.dart';
import 'file_browser_filter.dart';
import 'remote_permissions_dialog.dart';
import 'remote_text_editor.dart';

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
  final String? followedPath;
  const FilesPane({
    super.key,
    required this.connectionId,
    this.dropActive = true,
    this.followedPath,
  });
  @override
  State<FilesPane> createState() => FilesPaneState();
}

class FilesPaneState extends State<FilesPane> {
  native.DirectoryListing? listing;
  String? error;
  bool busy = false, dragging = false;
  String activity = '';
  bool scanningFolder = false, cancelFolderScan = false;
  UploadBatch? uploadBatch;
  FolderAccess? folderAccess;
  DownloadTask? downloadTask;
  native.RemoteEntry? downloadEntry;
  List<XFile> uploadSources = const [];
  final history = DirectoryHistory();
  final search = TextEditingController();
  bool showHidden = true, descending = false, follow = false;
  bool selecting = false;
  final selected = <String>{};
  FileSort sort = FileSort.name;
  final path = TextEditingController(text: '.');
  @override
  void initState() {
    super.initState();
    load('.');
  }

  @override
  void dispose() {
    uploadBatch?.cancelRemaining();
    folderAccess?.release().catchError((Object _) {});
    path.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FilesPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.followedPath;
    if (follow &&
        next != null &&
        next != oldWidget.followedPath &&
        !busy &&
        listing?.path != next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && follow) load(next);
      });
    }
  }

  List<native.RemoteEntry> get entries => filterRemoteEntries(
    listing?.entries ?? [],
    query: search.text,
    showHidden: showHidden,
    sort: sort,
    descending: descending,
  );

  Future<void> refresh() => load(listing?.path ?? '.');

  String _uniqueLocal(String directory, String name) {
    var candidate = '$directory/$name';
    var index = 1;
    while (File(candidate).existsSync()) {
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      candidate = '$directory/$stem ($index)$extension';
      index++;
    }
    return candidate;
  }

  Future<void> downloadSelected() async {
    final files = entries
        .where(
          (entry) =>
              selected.contains(entry.path) &&
              !entry.isDirectory &&
              !entry.isSymlink,
        )
        .toList();
    if (files.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请选择要下载的文件')));
      return;
    }
    if (Platform.isIOS) {
      Directory temp = await createAppTemporaryDirectory('wterm-batch-');
      setState(() {
        busy = true;
        activity = '准备批量下载…';
        error = null;
      });
      try {
        final shared = <XFile>[];
        for (var index = 0; index < files.length; index++) {
          final entry = files[index];
          if (!mounted) return;
          setState(
            () => activity = '下载 ${index + 1}/${files.length}：${entry.name}',
          );
          final local = '${temp.path}/${entry.name}';
          await native.downloadFile(
            connectionId: widget.connectionId,
            remotePath: entry.path,
            localPath: local,
          );
          shared.add(XFile(local));
        }
        await SharePlus.instance.share(
          ShareParams(files: shared, text: 'W Term · ${files.length} 个文件'),
        );
        if (mounted) {
          setState(() {
            selecting = false;
            selected.clear();
          });
        }
      } catch (e) {
        if (mounted) setState(() => error = '批量下载失败：${userFacingError(e)}');
      } finally {
        if (mounted) setState(() => busy = false);
        await temp.delete(recursive: true).catchError((Object _) => temp);
      }
      return;
    }
    final directory = await getDirectoryPath();
    if (directory == null || !mounted) return;
    setState(() {
      busy = true;
      activity = '准备批量下载…';
      error = null;
    });
    var completed = 0;
    try {
      for (final entry in files) {
        if (!mounted) return;
        setState(
          () => activity = '下载 ${completed + 1}/${files.length}：${entry.name}',
        );
        await native.downloadFile(
          connectionId: widget.connectionId,
          remotePath: entry.path,
          localPath: _uniqueLocal(directory, entry.name),
        );
        completed++;
      }
      if (mounted) {
        setState(() {
          selecting = false;
          selected.clear();
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已下载 $completed 个文件')));
      }
    } catch (e) {
      if (mounted) setState(() => error = '批量下载失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load(String target, {int? historyIndex}) async {
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
          history.commit(result.path, historyIndex: historyIndex);
          listing = result;
          path.text = result.path;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = userFacingError(e);
          if (listing != null) path.text = listing!.path;
        });
      }
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

  Future<void> uploadFolder({DropItemDirectory? dropped}) async {
    if (busy || listing == null) return;
    final destination = listing!.path;
    setState(() {
      busy = true;
      error = null;
      dragging = false;
      activity = '选择并扫描文件夹…';
    });
    List<FolderUploadItem>? plan;
    FolderAccess? selectedAccess;
    try {
      final String? selected;
      if (dropped != null) {
        selectedAccess = await FolderAccess.fromDrop(dropped);
        selected = selectedAccess.path;
      } else if (Platform.isIOS) {
        selectedAccess = await FolderAccess.pick();
        selected = selectedAccess?.path;
      } else {
        selected = await getDirectoryPath();
      }
      if (selected == null || !mounted) return;
      setState(() {
        scanningFolder = true;
        cancelFolderScan = false;
        activity = '正在扫描文件夹…';
      });
      plan = await planFolderUpload(
        selected,
        isCancelled: () => !mounted || cancelFolderScan,
        onProgress: (count) {
          if (mounted && (count == 1 || count % 20 == 0)) {
            setState(() => activity = '已扫描 $count 项…');
          }
        },
      );
      if (mounted) setState(() => scanningFolder = false);
      if (!mounted) return;
      final snapshot = plan;
      final selection = await showDialog<FolderUploadSelection>(
        context: context,
        builder: (_) =>
            FolderUploadPreview(items: snapshot, destination: destination),
      );
      plan = selection == null
          ? null
          : renameUploadRoot(
              selectFolderUploadItems(
                snapshot,
                includeHidden: selection.includeHidden,
              ),
              selection.targetName,
            );
    } on FolderScanCancelled {
      plan = null;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已取消文件夹扫描，未上传任何项目')));
      }
    } catch (e) {
      plan = null;
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (!mounted || plan == null) {
        await selectedAccess?.release();
        selectedAccess = null;
      }
      if (mounted) {
        setState(() {
          busy = false;
          scanningFolder = false;
        });
      }
    }
    if (mounted && plan != null) {
      await uploadFiles(
        plan,
        destination: destination,
        newFolderAccess: selectedAccess,
      );
    }
  }

  Future<void> showUploadTasks() async {
    final batch = uploadBatch;
    if (batch == null) return;
    final retry = await showDialog<bool>(
      context: context,
      builder: (_) =>
          UploadTasksDialog(batch: batch, allowRetry: !busy || batch.active),
    );
    if (retry == true && mounted && identical(batch, uploadBatch)) {
      await uploadFiles(uploadSources, retryBatch: batch);
    }
  }

  Future<void> uploadFiles(
    List<XFile> files, {
    String? destination,
    UploadBatch? retryBatch,
    FolderAccess? newFolderAccess,
  }) async {
    if (listing == null || busy || files.isEmpty) return;
    final directory = retryBatch?.destination ?? destination ?? listing!.path;
    final batch =
        retryBatch ??
        UploadBatch(
          directory,
          files.map(
            (file) => file is FolderUploadItem ? file.relativePath : file.name,
          ),
        );
    final indices = retryBatch == null
        ? List.generate(files.length, (i) => i)
        : batch.retryFailures();
    if (indices.isEmpty) return;
    if (retryBatch == null) {
      final previous = folderAccess;
      folderAccess = newFolderAccess;
      previous?.release().catchError((Object _) {});
    }
    final transferAccess = folderAccess;
    transferAccess?.retain();
    setState(() {
      busy = true;
      dragging = false;
      error = null;
    });
    setState(() {
      uploadBatch = batch;
      uploadSources = List.unmodifiable(files);
    });
    final conflictDecisions = UploadConflictDecisions();
    var uploaded = 0;
    var skipped = 0;
    var cancelled = false;
    final failures = <String>[];
    try {
      for (final index in indices) {
        if (!mounted || !batch.start(index)) break;
        final file = files[index];
        Directory? temporary;
        var scoped = false;
        final bookmark = file is DropItem ? file.extraAppleBookmark : null;
        try {
          final name = file.name;
          final relative = file is FolderUploadItem ? file.relativePath : name;
          if (file is FolderUploadItem) {
            final parent = file.parentIndex;
            if (parent != null &&
                batch.tasks[parent].state != UploadState.completed) {
              throw const FormatException('父文件夹未创建，未上传此项目');
            }
            var ancestor = parent;
            while (ancestor != null) {
              final parentFile = files[ancestor] as FolderUploadItem;
              if (await FileSystemEntity.type(
                    parentFile.path,
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.directory) {
                throw const FormatException('本地父目录类型已变化，请重新选择文件夹');
              }
              ancestor = parentFile.parentIndex;
            }
            if (await FileSystemEntity.type(file.path, followLinks: false) !=
                (file.isDirectory
                    ? FileSystemEntityType.directory
                    : FileSystemEntityType.file)) {
              throw const FormatException('本地项目类型已变化，请重新选择文件夹');
            }
            if (file.isDirectory) {
              await native.createDirectory(
                connectionId: widget.connectionId,
                path: '${directory == '/' ? '' : directory}/$relative',
              );
              batch.complete(index, '已创建文件夹');
              continue;
            }
          }
          if (name.isEmpty ||
              name.contains('/') ||
              name.contains('\x00') ||
              name == '.' ||
              name == '..') {
            throw const FormatException('无效的文件名');
          }
          setState(() => activity = '上传 $name（${index + 1}/${files.length}）…');
          if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
            scoped = await DesktopDrop.instance
                .startAccessingSecurityScopedResource(bookmark: bookmark);
            if (!scoped) {
              throw const FileSystemException('无法获得拖入文件的访问权限，请使用上传按钮选择文件');
            }
          }
          if (await FileSystemEntity.type(file.path) !=
              FileSystemEntityType.file) {
            throw const FormatException('此入口仅支持文件；文件夹请通过上传菜单选择');
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
                remotePath: '${directory == '/' ? '' : directory}/$relative',
                policy: policy,
              );
              uploaded++;
              batch.complete(
                index,
                '${result.remotePath} · ${formatSize(result.bytes)}',
              );
              if (mounted) {
                setState(
                  () => activity =
                      '已上传 ${result.remotePath.split('/').last} · ${formatSize(result.bytes)}',
                );
              }
              break;
            } catch (e) {
              if (policy != 'reject' ||
                  !e.toString().contains('Destination already exists') ||
                  !mounted) {
                rethrow;
              }
              final choice = await conflictDecisions.resolve(
                () => chooseUploadConflict(context, relative),
              );
              if (choice == null) {
                cancelled = true;
                batch.cancelCurrent(index);
                batch.cancelRemaining();
                break;
              }
              if (choice == 'skip') {
                batch.skip(index);
                skipped++;
                break;
              }
              policy = choice;
            }
          }
        } catch (e) {
          final message = userFacingError(e);
          batch.fail(index, message);
          failures.add('${file.name}：$message');
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
      cancelled = cancelled || batch.cancelRequested;
      try {
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
                  '已上传 $uploaded 个文件${skipped == 0 ? '' : '，跳过 $skipped 个'}${cancelled ? '，已取消剩余上传' : ''}${failures.isEmpty ? '' : '，${failures.length} 个失败'}',
                ),
              ),
            );
          }
        }
      } finally {
        batch.finish();
        await transferAccess?.release();
      }
    }
  }

  Future<void> showDownloadTask() async {
    final task = downloadTask;
    final entry = downloadEntry;
    if (task == null || entry == null) return;
    final retry = await showDialog<bool>(
      context: context,
      builder: (_) =>
          DownloadTaskDialog(task: task, allowRetry: !busy || task.active),
    );
    if (retry == true && mounted && !busy) await download(entry);
  }

  Future<void> download(native.RemoteEntry entry) async {
    if (busy) return;
    Directory? temporary;
    String? local;
    final task = DownloadTask(entry.name, entry.path);
    setState(() {
      busy = true;
      error = null;
      activity = '下载 ${entry.name}…';
      downloadTask = task;
      downloadEntry = entry;
    });
    await task.run(
      fetch: () async {
        temporary = await createAppTemporaryDirectory('wterm-download-');
        // Never use a remote name as a local path.
        local = '${temporary!.path}/download';
        return native.downloadFile(
          connectionId: widget.connectionId,
          remotePath: entry.path,
          localPath: local!,
        );
      },
      deliver: () async {
        if (!mounted) return DownloadOutcome.cancelled;
        setState(() => activity = '等待保存或分享 ${entry.name}…');
        if (Platform.isIOS) {
          final box = context.findRenderObject() as RenderBox;
          final result = await SharePlus.instance.share(
            ShareParams(
              files: [XFile(local!)],
              fileNameOverrides: [entry.name],
              sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
            ),
          );
          return switch (result.status) {
            ShareResultStatus.success => DownloadOutcome.shared,
            ShareResultStatus.dismissed => DownloadOutcome.cancelled,
            ShareResultStatus.unavailable => DownloadOutcome.unconfirmed,
          };
        }
        final destination = await getSaveLocation(suggestedName: entry.name);
        if (destination == null || !mounted) return DownloadOutcome.cancelled;
        await XFile(local!).saveTo(destination.path);
        return DownloadOutcome.saved;
      },
      cleanup: () async {
        if (temporary != null && await temporary!.exists()) {
          await temporary!.delete(recursive: true);
        }
      },
    );
    if (mounted) {
      setState(() {
        busy = false;
        error = [
          task.error,
          task.cleanupWarning,
        ].whereType<String>().join('\n');
        if (error!.isEmpty) error = null;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(task.status)));
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

  Future<void> mutateEntry(
    native.RemoteEntry entry, {
    required bool delete,
  }) async {
    if (busy || listing == null) return;
    final directory = listing!.path;
    String? name;
    if (delete) {
      final confirmed = await confirmRemoteDelete(
        context,
        name: entry.name,
        isDirectory: entry.isDirectory,
        isSymlink: entry.isSymlink,
      );
      if (!confirmed || !mounted) return;
    } else {
      name = await nameDialog('重命名', entry.name);
      if (name == null || name == entry.name || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
      activity = delete ? '删除项目…' : '重命名…';
    });
    String? failure;
    try {
      if (delete) {
        await native.deleteRemoteEntry(
          connectionId: widget.connectionId,
          path: entry.path,
        );
      } else {
        await native.renameRemoteEntry(
          connectionId: widget.connectionId,
          path: entry.path,
          name: name!,
        );
      }
    } catch (e) {
      failure = userFacingError(e);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await load(directory);
        if (mounted) {
          if (failure != null) {
            setState(() => error = failure);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(delete ? '已删除 ${entry.name}' : '已重命名为 $name'),
              ),
            );
          }
        }
      }
    }
  }

  Future<void> editPermissions(native.RemoteEntry entry) async {
    if (busy || listing == null || entry.isSymlink) return;
    final directory = listing!.path;
    setState(() {
      busy = true;
      error = null;
      activity = '读取权限…';
    });
    var changed = false;
    try {
      final permissions = await native.remotePermissions(
        connectionId: widget.connectionId,
        path: entry.path,
      );
      if (!mounted) return;
      changed =
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => RemotePermissionsDialog(
              name: entry.name,
              permissions: permissions,
              onSave: (value) => native.changeRemotePermissions(
                connectionId: widget.connectionId,
                path: entry.path,
                expected: permissions,
                permissions: value,
              ),
            ),
          ) ??
          false;
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (changed) {
          await load(directory);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('权限已更新')));
          }
        }
      }
    }
  }

  Future<void> editText(native.RemoteEntry entry) async {
    if (busy || listing == null || entry.isDirectory || entry.isSymlink) return;
    final directory = listing!.path;
    setState(() {
      busy = true;
      error = null;
      activity = '读取文本…';
    });
    var saved = false;
    try {
      final snapshot = await native.readRemoteText(
        connectionId: widget.connectionId,
        path: entry.path,
      );
      if (!mounted) return;
      saved =
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => RemoteTextEditor(
              name: entry.name,
              text: snapshot.text,
              onSave: (text) => native.saveRemoteText(
                connectionId: widget.connectionId,
                path: entry.path,
                expected: snapshot,
                text: text,
              ),
            ),
          ) ??
          false;
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (saved) {
          await load(directory);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('文本已保存')));
          }
        }
      }
    }
  }

  void setDragging(bool value) {
    Future.microtask(() {
      if (mounted) setState(() => dragging = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = filterRemoteEntries(
      listing?.entries ?? [],
      query: search.text,
      showHidden: showHidden,
      sort: sort,
      descending: descending,
    );
    return DropTarget(
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
          if (busy || listing == null) return;
          try {
            final folder = droppedFolder(details.files);
            if (folder != null) {
              uploadFolder(dropped: folder);
            } else {
              uploadFiles(details.files);
            }
          } catch (e) {
            setState(() {
              dragging = false;
              error = userFacingError(e);
            });
          }
        }
      },
      child: Stack(
        children: [
          Column(
            children: [
              DirectoryHistoryBar(
                history: history,
                busy: busy,
                onNavigate: (index) =>
                    load(history.paths[index], historyIndex: index),
              ),
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
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'Menlo',
                        ),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.folder_outlined, size: 18),
                        ),
                        onSubmitted: load,
                      ),
                    ),
                    IconButton(
                      tooltip: follow ? '停止跟随终端目录' : '跟随终端目录',
                      onPressed: () {
                        setState(() => follow = !follow);
                        final target = widget.followedPath;
                        if (follow && target != null && !busy) load(target);
                      },
                      icon: Icon(
                        follow ? Icons.link : Icons.link_off,
                        size: 19,
                        color: follow
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                    IconButton(
                      tooltip: selecting ? '取消多选' : '多选文件',
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              selecting = !selecting;
                              if (!selecting) selected.clear();
                            }),
                      icon: Icon(
                        selecting ? Icons.close : Icons.checklist,
                        size: 19,
                        color: selecting
                            ? Theme.of(context).colorScheme.primary
                            : null,
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
                      '${entries.length} / ${listing?.entries.length ?? 0} 个项目',
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
                    if (uploadBatch != null || downloadTask != null)
                      PopupMenuButton<String>(
                        tooltip: '传输任务',
                        icon: const Icon(Icons.playlist_add_check, size: 19),
                        onSelected: (value) {
                          if (value == 'upload') {
                            showUploadTasks();
                          } else {
                            showDownloadTask();
                          }
                        },
                        itemBuilder: (_) => [
                          if (uploadBatch != null)
                            const PopupMenuItem(
                              value: 'upload',
                              child: Text('上传任务'),
                            ),
                          if (downloadTask != null)
                            const PopupMenuItem(
                              value: 'download',
                              child: Text('最近下载'),
                            ),
                        ],
                      ),
                    PopupMenuButton<String>(
                      tooltip: '上传',
                      enabled: !busy && listing != null,
                      icon: const Icon(Icons.upload_outlined, size: 19),
                      onSelected: (value) {
                        if (value == 'folder') {
                          uploadFolder();
                        } else {
                          upload();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'files',
                          child: Text('上传文件'),
                        ),
                        if (Platform.isMacOS || Platform.isIOS)
                          const PopupMenuItem(
                            value: 'folder',
                            child: Text('上传文件夹'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              FileBrowserControls(
                search: search,
                showHidden: showHidden,
                descending: descending,
                sort: sort,
                onFilterChanged: () => setState(() {}),
                onToggleHidden: () => setState(() => showHidden = !showHidden),
                onToggleDirection: () =>
                    setState(() => descending = !descending),
                onSort: (value) => setState(() => sort = value),
              ),
              if (selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Row(
                    children: [
                      Text(
                        '已选 ${selected.length} 个文件',
                        style: const TextStyle(fontSize: 11),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                selected.addAll(
                                  entries
                                      .where(
                                        (entry) =>
                                            !entry.isDirectory &&
                                            !entry.isSymlink,
                                      )
                                      .map((entry) => entry.path),
                                );
                              }),
                        child: const Text('全选文件'),
                      ),
                      FilledButton(
                        onPressed: busy ? null : downloadSelected,
                        child: const Text('下载所选'),
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
              if (scanningFolder)
                TextButton(
                  onPressed: cancelFolderScan
                      ? null
                      : () => setState(() {
                          cancelFolderScan = true;
                          activity = '正在取消扫描…';
                        }),
                  child: Text(cancelFolderScan ? '正在取消…' : '取消扫描'),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: listing == null
                    ? Center(child: Text(busy ? '连接 SFTP…' : '无法读取目录'))
                    : entries.isEmpty
                    ? Center(
                        child: Text(
                          listing!.entries.isEmpty
                              ? '此文件夹为空'
                              : '没有匹配项目，请调整搜索或隐藏文件设置',
                        ),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return ListTile(
                            dense: true,
                            enabled: !busy,
                            leading: selecting
                                ? Checkbox(
                                    value: selected.contains(entry.path),
                                    onChanged: busy
                                        ? null
                                        : (_) => setState(() {
                                            if (!selected.remove(entry.path)) {
                                              selected.add(entry.path);
                                            }
                                          }),
                                  )
                                : Icon(
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
                            subtitle: Text(
                              '${entry.isDirectory ? "" : "${formatSize(entry.size)} · "}${remoteModifiedLabel(entry.modifiedAt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: selecting
                                ? () => setState(() {
                                    if (!selected.remove(entry.path)) {
                                      selected.add(entry.path);
                                    }
                                  })
                                : () => entry.isDirectory
                                      ? load(entry.path)
                                      : preview(entry),
                            trailing: RemoteEntryActions(
                              enabled: !busy,
                              isDirectory: entry.isDirectory,
                              onDownload: () => download(entry),
                              onEdit: entry.isDirectory || entry.isSymlink
                                  ? null
                                  : () => editText(entry),
                              onPermissions: entry.isSymlink
                                  ? null
                                  : () => editPermissions(entry),
                              onRename: () => mutateEntry(entry, delete: false),
                              onDelete: () => mutateEntry(entry, delete: true),
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
                    '松开上传文件或单个文件夹到\n${listing?.path ?? ""}',
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
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
