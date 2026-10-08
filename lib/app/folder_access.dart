import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';

/// A session-only Apple security scope, retained while a transfer is still running.
class FolderAccess {
  static const channel = MethodChannel('dev.wterm/folders');
  final String path;
  final String token;
  final Future<void> Function()? _onRelease;
  int _references = 1;
  FolderAccess._(this.path, this.token, [this._onRelease]);

  static Future<FolderAccess?> pick() async {
    final result = await channel.invokeMapMethod<String, dynamic>('pick');
    if (result == null) return null;
    return FolderAccess._(result['path'] as String, result['token'] as String);
  }

  static Future<FolderAccess> fromDrop(DropItemDirectory item) async {
    final bytes = item.extraAppleBookmark;
    if (bytes == null || bytes.isEmpty) {
      // Promised items already in the container need no security scope.
      return FolderAccess._(item.path, '', () async {});
    }
    final bookmark = Uint8List.fromList(bytes);
    final granted = await DesktopDrop.instance
        .startAccessingSecurityScopedResource(bookmark: bookmark);
    if (!granted) throw StateError('无法获得拖入文件夹的访问权限，请使用上传菜单选择');
    return FolderAccess._(item.path, '', () async {
      await DesktopDrop.instance.stopAccessingSecurityScopedResource(
        bookmark: bookmark,
      );
    });
  }

  void retain() {
    if (_references == 0) throw StateError('文件夹授权已释放，请重新选择');
    _references++;
  }

  Future<void> release() async {
    if (_references == 0) return;
    _references--;
    if (_references == 0) {
      if (_onRelease != null) {
        await _onRelease();
      } else {
        await channel.invokeMethod<void>('release', token);
      }
    }
  }
}
