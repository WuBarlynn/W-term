/// Shell-command palette used by the completion plugin. Entries are curated
/// descriptions, not a replacement for the remote shell's own completion.
const commandCompletionCatalog = <String, List<(String, String)>>{
  'git': [
    ('add', '暂存变更'),
    ('branch', '管理分支'),
    ('checkout', '切换分支或文件'),
    ('switch', '切换分支'),
    ('cherry-pick', '拣选提交'),
    ('clone', '克隆仓库'),
    ('commit', '提交变更'),
    ('diff', '查看差异'),
    ('fetch', '获取远程更新'),
    ('log', '查看提交历史'),
    ('merge', '合并分支'),
    ('pull', '拉取并合并'),
    ('push', '推送提交'),
    ('rebase', '变基'),
    ('remote', '管理远程仓库'),
    ('reset', '重置提交'),
    ('restore', '恢复文件'),
    ('revert', '撤销提交'),
    ('show', '查看对象内容'),
    ('stash', '暂存工作区'),
    ('status', '查看工作区状态'),
    ('tag', '管理标签'),
    ('worktree', '管理多工作树'),
  ],
  'docker': [
    ('build', '构建镜像'),
    ('compose', '编排容器'),
    ('container', '管理容器'),
    ('exec', '进入容器执行命令'),
    ('images', '列出镜像'),
    ('inspect', '查看对象详情'),
    ('logs', '查看容器日志'),
    ('network', '管理网络'),
    ('ps', '列出容器'),
    ('pull', '拉取镜像'),
    ('push', '推送镜像'),
    ('restart', '重启容器'),
    ('rm', '删除容器'),
    ('rmi', '删除镜像'),
    ('run', '运行新容器'),
    ('start', '启动容器'),
    ('stop', '停止容器'),
    ('volume', '管理数据卷'),
  ],
  'docker compose': [
    ('up', '创建并启动服务'),
    ('down', '停止并移除服务'),
    ('ps', '列出服务'),
    ('logs', '查看服务日志'),
    ('restart', '重启服务'),
    ('build', '构建服务镜像'),
    ('pull', '拉取服务镜像'),
    ('exec', '在服务中执行命令'),
    ('config', '校验并查看配置'),
  ],
  'kubectl': [
    ('apply', '应用清单'),
    ('describe', '查看资源详情'),
    ('delete', '删除资源'),
    ('edit', '编辑资源'),
    ('exec', '进入 Pod 执行命令'),
    ('get', '列出资源'),
    ('logs', '查看 Pod 日志'),
    ('port-forward', '端口转发'),
    ('rollout', '管理发布'),
    ('scale', '调整副本数'),
    ('top', '查看资源用量'),
    ('config', '管理 kubeconfig'),
  ],
  'systemctl': [
    ('status', '查看服务状态'),
    ('start', '启动服务'),
    ('stop', '停止服务'),
    ('restart', '重启服务'),
    ('reload', '重载配置'),
    ('enable', '设置开机启动'),
    ('disable', '取消开机启动'),
    ('list-units', '列出单元'),
    ('daemon-reload', '重载 systemd 配置'),
  ],
  'journalctl': [
    ('-u', '按服务筛选日志'),
    ('-f', '持续跟踪日志'),
    ('--since', '按时间筛选'),
    ('--until', '按结束时间筛选'),
    ('-p', '按日志级别筛选'),
    ('--disk-usage', '查看日志占用'),
  ],
  'apt': [
    ('update', '更新软件源'),
    ('upgrade', '升级软件包'),
    ('install', '安装软件包'),
    ('remove', '卸载软件包'),
    ('autoremove', '清理无用依赖'),
    ('search', '搜索软件包'),
    ('list', '列出软件包'),
    ('show', '查看软件包信息'),
    ('policy', '查看版本策略'),
  ],
  'dnf': [
    ('install', '安装软件包'),
    ('remove', '卸载软件包'),
    ('update', '更新软件包'),
    ('search', '搜索软件包'),
    ('list', '列出软件包'),
    ('info', '查看软件包信息'),
    ('repolist', '列出软件源'),
  ],
  'brew': [
    ('install', '安装软件包'),
    ('uninstall', '卸载软件包'),
    ('upgrade', '升级软件包'),
    ('list', '列出已安装包'),
    ('search', '搜索软件包'),
    ('services', '管理后台服务'),
    ('update', '更新 Homebrew'),
    ('doctor', '检查环境'),
  ],
  'npm': [
    ('install', '安装依赖'),
    ('ci', '按锁文件安装'),
    ('run', '运行脚本'),
    ('test', '运行测试'),
    ('start', '启动项目'),
    ('build', '构建项目'),
    ('update', '更新依赖'),
    ('audit', '检查依赖漏洞'),
    ('publish', '发布包'),
  ],
  'pnpm': [
    ('install', '安装依赖'),
    ('add', '添加依赖'),
    ('remove', '移除依赖'),
    ('run', '运行脚本'),
    ('test', '运行测试'),
    ('build', '构建项目'),
    ('update', '更新依赖'),
    ('publish', '发布包'),
  ],
  'yarn': [
    ('install', '安装依赖'),
    ('add', '添加依赖'),
    ('remove', '移除依赖'),
    ('run', '运行脚本'),
    ('test', '运行测试'),
    ('build', '构建项目'),
    ('upgrade', '升级依赖'),
  ],
  'cargo': [
    ('build', '编译项目'),
    ('check', '检查代码'),
    ('run', '运行项目'),
    ('test', '运行测试'),
    ('fmt', '格式化代码'),
    ('clippy', '运行 Clippy'),
    ('add', '添加依赖'),
    ('publish', '发布包'),
    ('update', '更新依赖'),
  ],
  'pip': [
    ('install', '安装包'),
    ('uninstall', '卸载包'),
    ('list', '列出包'),
    ('show', '查看包信息'),
    ('freeze', '导出依赖'),
    ('download', '下载包'),
  ],
  'go': [
    ('build', '编译项目'),
    ('run', '运行项目'),
    ('test', '运行测试'),
    ('mod', '管理模块'),
    ('get', '获取依赖'),
    ('fmt', '格式化代码'),
    ('vet', '静态检查'),
    ('generate', '运行代码生成'),
  ],
  'ssh': [
    ('-p', '指定端口'),
    ('-i', '指定私钥'),
    ('-L', '本地端口转发'),
    ('-R', '远程端口转发'),
    ('-D', '动态端口转发'),
    ('-J', '跳板机'),
    ('-v', '输出调试信息'),
    ('-N', '不执行远程命令'),
  ],
  'scp': [
    ('-r', '递归复制'),
    ('-P', '指定端口'),
    ('-i', '指定私钥'),
    ('-p', '保留时间戳'),
    ('-C', '压缩传输'),
  ],
  'rsync': [
    ('-avz', '归档压缩同步'),
    ('-e', '指定远程 shell'),
    ('--delete', '删除目标多余文件'),
    ('--exclude', '排除文件'),
    ('--include', '包含文件'),
    ('--dry-run', '预演同步'),
    ('--progress', '显示进度'),
  ],
  'tar': [
    ('-czf', '创建 gzip 压缩包'),
    ('-xzf', '解压 gzip 压缩包'),
    ('-cjf', '创建 bzip2 压缩包'),
    ('-xjf', '解压 bzip2 压缩包'),
    ('-tzf', '列出压缩包内容'),
    ('-C', '指定目录'),
  ],
  'tmux': [
    ('new-session', '新建会话'),
    ('attach', '连接会话'),
    ('list-sessions', '列出会话'),
    ('kill-session', '结束会话'),
    ('new-window', '新建窗口'),
    ('split-window', '分屏'),
    ('capture-pane', '捕获窗格内容'),
    ('send-keys', '发送按键'),
    ('rename-session', '重命名会话'),
  ],
  'curl': [
    ('-I', '只看响应头'),
    ('-L', '跟随重定向'),
    ('-o', '输出到文件'),
    ('-O', '用远程文件名保存'),
    ('-X', '指定请求方法'),
    ('-H', '添加请求头'),
    ('-d', '发送请求体'),
    ('-k', '跳过证书校验'),
    ('-s', '静默模式'),
  ],
  'ps': [
    ('aux', '查看所有进程'),
    ('-ef', '查看完整进程信息'),
    ('-eo', '自定义输出列'),
    ('--sort', '按列排序'),
  ],
  'kill': [('-9', '强制终止'), ('-15', '优雅终止'), ('-HUP', '挂起信号')],
  'find': [
    ('-name', '按名称匹配'),
    ('-type', '按类型匹配'),
    ('-size', '按大小匹配'),
    ('-mtime', '按修改时间匹配'),
    ('-exec', '对结果执行命令'),
    ('-delete', '删除结果'),
  ],
  'chmod': [
    ('+x', '添加执行权限'),
    ('-R', '递归修改'),
    ('755', '常见文件权限'),
    ('644', '常见文件权限'),
  ],
  'systemd-analyze': [
    ('blame', '查看启动耗时'),
    ('critical-chain', '查看启动链路'),
    ('verify', '校验单元文件'),
  ],
};

class CommandCompletion {
  final String value, description, group;
  const CommandCompletion({
    required this.value,
    required this.description,
    required this.group,
  });
}

/// Returns completions for the token being typed. Only the first (and for
/// `docker compose` the second) argument level is covered; arbitrary command
/// arguments fall through to the shell.
List<CommandCompletion> commandSuggestions(String input, {int limit = 6}) {
  if (input.contains('\n') || input.contains('\r')) return const [];
  final text = input.trimLeft();
  if (text.isEmpty) return const [];
  final trailingSpace = RegExp(r'\s$').hasMatch(text);
  final tokens = text.trimRight().split(RegExp(r'\s+'));
  final current = trailingSpace ? '' : tokens.last;
  final complete = trailingSpace
      ? tokens
      : tokens.sublist(0, tokens.length - 1);

  for (var depth = complete.length.clamp(0, 3); depth >= 1; depth--) {
    final group = complete.take(depth).join(' ');
    final entries = commandCompletionCatalog[group];
    if (entries == null) continue;
    if (depth < complete.length) return const [];
    return entries
        .where((entry) => entry.$1 != current && entry.$1.startsWith(current))
        .take(limit)
        .map(
          (entry) => CommandCompletion(
            value: entry.$1,
            description: entry.$2,
            group: group,
          ),
        )
        .toList();
  }

  if (complete.isEmpty && !trailingSpace) {
    final exact = commandCompletionCatalog[current];
    if (exact != null) {
      return exact
          .take(limit)
          .map(
            (entry) => CommandCompletion(
              value: entry.$1,
              description: entry.$2,
              group: current,
            ),
          )
          .toList();
    }
    return commandCompletionCatalog.keys
        .where((command) => command != current && command.startsWith(current))
        .take(limit)
        .map(
          (command) =>
              CommandCompletion(value: command, description: '命令', group: ''),
        )
        .toList();
  }
  return const [];
}

/// Bytes that complete [completion] relative to [input] without executing it.
String completionInsertion(String input, CommandCompletion completion) {
  final trailingSpace = RegExp(r'\s$').hasMatch(input);
  final trimmed = input.trimLeft();
  final tokens = input.trimRight().split(RegExp(r'\s+'));
  final current = trailingSpace ? '' : tokens.last;
  if (current.isNotEmpty && completion.value.startsWith(current)) {
    return '${completion.value.substring(current.length)} ';
  }
  if (completion.group.isNotEmpty && trimmed == completion.group) {
    return ' ${completion.value} ';
  }
  return '${completion.value} ';
}

/// Tracks the shell line currently being typed. It intentionally becomes
/// unseen after cursor movement, because cursor keys are not replayed here.
class TerminalInputTracker {
  final _line = StringBuffer();
  bool _visible = true;
  bool _escape = false;

  String get current => _visible ? _line.toString() : '';

  void feed(String text) {
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (_escape) {
        if (RegExp(r'[A-Za-z~]').hasMatch(char)) _escape = false;
        continue;
      }
      if (rune == 0x1b) {
        _escape = true;
        _visible = false;
        continue;
      }
      if (rune == 0x0a || rune == 0x0d) {
        _line.clear();
        _visible = true;
        continue;
      }
      if (rune == 0x03 || rune == 0x15) {
        _line.clear();
        _visible = true;
        continue;
      }
      if (rune == 0x17) {
        final value = _line.toString();
        final match = RegExp(r'\S+\s*$').firstMatch(value);
        if (match != null) {
          _line
            ..clear()
            ..write(value.substring(0, match.start));
        }
        continue;
      }
      if (rune == 0x7f || rune == 0x08) {
        final value = _line.toString();
        if (value.isNotEmpty) {
          _line
            ..clear()
            ..write(value.substring(0, value.length - 1));
        }
        continue;
      }
      if (rune < 0x20) continue;
      if (!_visible) continue;
      if (_line.length < 4096) _line.write(char);
    }
  }
}
