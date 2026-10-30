class SnippetCatalogEntry {
  final String name, category, command;
  const SnippetCatalogEntry(this.name, this.category, this.command);
}

/// Read-only official-style examples bundled with the app. They are not
/// destructive and can be added to the encrypted local library.
const snippetCatalog = <SnippetCatalogEntry>[
  SnippetCatalogEntry('系统负载', '系统诊断', 'uptime'),
  SnippetCatalogEntry('内存使用', '系统诊断', 'free -h'),
  SnippetCatalogEntry('磁盘空间', '系统诊断', 'df -h'),
  SnippetCatalogEntry('CPU 占用前 20', '系统诊断', 'top -bn1 | head -20'),
  SnippetCatalogEntry('失败的服务', '系统诊断', 'systemctl --failed'),
  SnippetCatalogEntry('最近日志', '系统诊断', 'journalctl -xe --no-pager | tail -100'),
  SnippetCatalogEntry('系统信息', '系统诊断', 'uname -a'),
  SnippetCatalogEntry('CPU 信息', '系统诊断', 'lscpu'),
  SnippetCatalogEntry('块设备', '系统诊断', 'lsblk'),
  SnippetCatalogEntry('登录用户', '系统诊断', 'who -a'),
  SnippetCatalogEntry('监听端口', '网络', 'ss -tulpn'),
  SnippetCatalogEntry('网卡地址', '网络', 'ip addr'),
  SnippetCatalogEntry('路由表', '网络', 'ip route'),
  SnippetCatalogEntry('连通性测试', '网络', 'ping -c 4 1.1.1.1'),
  SnippetCatalogEntry('DNS 查询', '网络', 'dig +short example.com'),
  SnippetCatalogEntry('HTTP 响应头', '网络', 'curl -I https://example.com'),
  SnippetCatalogEntry('路由追踪', '网络', 'traceroute 1.1.1.1'),
  SnippetCatalogEntry('网络统计', '网络', 'nstat -az | head -40'),
  SnippetCatalogEntry('运行中的容器', '容器', 'docker ps'),
  SnippetCatalogEntry('容器资源', '容器', 'docker stats --no-stream'),
  SnippetCatalogEntry('本地镜像', '容器', 'docker images'),
  SnippetCatalogEntry('容器日志', '容器', 'docker logs --tail 100 CONTAINER'),
  SnippetCatalogEntry('Kubernetes Pods', '容器', 'kubectl get pods -A'),
  SnippetCatalogEntry('Docker 服务状态', '容器', 'systemctl status docker'),
  SnippetCatalogEntry(
    '最近修改文件',
    '文件',
    'find . -maxdepth 2 -type f -printf "%T@ %p\\n" | sort -nr | head -20',
  ),
  SnippetCatalogEntry('目录占用', '文件', 'du -sh * | sort -h | tail -20'),
  SnippetCatalogEntry('详细列表', '文件', 'ls -lah'),
  SnippetCatalogEntry('文件元信息', '文件', 'stat .'),
  SnippetCatalogEntry('搜索 TODO', '文件', 'grep -RIn "TODO" . | head -50'),
  SnippetCatalogEntry('最近登录', '安全', 'last -n 20'),
  SnippetCatalogEntry('SSH 今日日志', '安全', 'journalctl -u ssh --since today'),
  SnippetCatalogEntry('当前 sudo 权限', '安全', 'sudo -l'),
];
