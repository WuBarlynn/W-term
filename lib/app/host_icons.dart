import 'package:flutter/material.dart';

class HostIconOption {
  final String key, name, keywords;
  final IconData icon;
  const HostIconOption(this.key, this.name, this.keywords, this.icon);
}

const hostIconCatalog = <HostIconOption>[
  HostIconOption('', '默认服务器', 'server 服务器 默认', Icons.dns_outlined),
  HostIconOption('terminal', '终端', 'terminal shell 终端 命令行', Icons.terminal),
  HostIconOption(
    'database',
    '数据库',
    'database db mysql 数据库',
    Icons.storage_outlined,
  ),
  HostIconOption('cloud', '云主机', 'cloud 云 主机', Icons.cloud_outlined),
  HostIconOption('code', '开发', 'code dev 开发 代码', Icons.code),
  HostIconOption('globe', '公网', 'globe internet 公网 网络', Icons.public),
  HostIconOption('security', '安全', 'security shield 安全 防护', Icons.security),
  HostIconOption('web', '网站', 'web site 网站', Icons.language),
  HostIconOption(
    'rocket',
    '构建',
    'build ci rocket 构建 发布',
    Icons.rocket_launch_outlined,
  ),
  HostIconOption('server', '机房', 'server rack 服务器 机房', Icons.dns),
  HostIconOption(
    'desktop',
    '桌面',
    'desktop pc 桌面 电脑',
    Icons.desktop_windows_outlined,
  ),
  HostIconOption('laptop', '笔记本', 'laptop 笔记本 便携', Icons.laptop_mac),
  HostIconOption('phone', '移动设备', 'phone mobile 手机 移动', Icons.smartphone),
  HostIconOption(
    'router',
    '路由交换',
    'router network 路由 交换 网络',
    Icons.router_outlined,
  ),
  HostIconOption('wifi', '无线', 'wifi wireless 无线', Icons.wifi),
  HostIconOption(
    'ethernet',
    '专线',
    'ethernet cable 专线 网线',
    Icons.settings_ethernet,
  ),
  HostIconOption('storage', '存储', 'storage disk 存储 磁盘', Icons.storage),
  HostIconOption(
    'archive',
    '归档',
    'archive backup 归档 备份',
    Icons.inventory_2_outlined,
  ),
  HostIconOption('backup', '备份', 'backup restore 备份 恢复', Icons.backup_outlined),
  HostIconOption('memory', '内存计算', 'memory cpu 内存 计算', Icons.memory),
  HostIconOption('speed', '高性能', 'speed fast 高性能 加速', Icons.speed),
  HostIconOption(
    'monitor',
    '监控',
    'monitor dashboard 监控 仪表盘',
    Icons.monitor_heart_outlined,
  ),
  HostIconOption(
    'analytics',
    '分析',
    'analytics chart 分析 图表',
    Icons.analytics_outlined,
  ),
  HostIconOption('bug', '测试', 'bug test 缺陷 测试', Icons.bug_report_outlined),
  HostIconOption('build', '流水线', 'build pipeline 流水线 编译', Icons.build_outlined),
  HostIconOption(
    'container',
    '容器',
    'container docker 容器',
    Icons.view_in_ar_outlined,
  ),
  HostIconOption(
    'kubernetes',
    'Kubernetes',
    'kubernetes k8s 集群',
    Icons.hub_outlined,
  ),
  HostIconOption('git', 'Git', 'git 版本控制 代码', Icons.commit),
  HostIconOption('branch', '分支', 'branch git 分支', Icons.alt_route),
  HostIconOption('api', 'API', 'api interface 接口', Icons.api),
  HostIconOption(
    'queue',
    '消息队列',
    'queue mq kafka 消息 队列',
    Icons.dynamic_feed_outlined,
  ),
  HostIconOption('cache', '缓存', 'cache redis 缓存', Icons.bolt_outlined),
  HostIconOption('mail', '邮件', 'mail smtp 邮件 邮箱', Icons.mail_outline),
  HostIconOption('dns', 'DNS', 'dns domain 域名 解析', Icons.travel_explore),
  HostIconOption('proxy', '代理', 'proxy gateway 代理 网关', Icons.swap_horiz),
  HostIconOption('vpn', 'VPN', 'vpn tunnel 隧道', Icons.vpn_lock_outlined),
  HostIconOption(
    'firewall',
    '防火墙',
    'firewall 防火墙',
    Icons.shield_outlined,
  ),
  HostIconOption('key', '密钥', 'key ssh 密钥 凭证', Icons.key_outlined),
  HostIconOption('lock', '加密', 'lock encrypt 加密 锁', Icons.lock_outline),
  HostIconOption(
    'verified',
    '可信',
    'verified trust 可信 认证',
    Icons.verified_outlined,
  ),
  HostIconOption('linux', 'Linux', 'linux penguin', Icons.computer),
  HostIconOption('apple', 'Apple', 'apple macos 苹果', Icons.apple),
  HostIconOption('windows', 'Windows', 'windows 微软', Icons.window),
  HostIconOption('android', 'Android', 'android 安卓', Icons.android),
  HostIconOption(
    'docker',
    'Docker',
    'docker container 容器',
    Icons.settings_suggest_outlined,
  ),
  HostIconOption('gpu', 'GPU', 'gpu 显卡 计算', Icons.developer_board_outlined),
  HostIconOption('power', '电源', 'power energy 电源 能源', Icons.power_settings_new),
  HostIconOption('science', '实验', 'lab science 实验 研究', Icons.science_outlined),
  HostIconOption('home', '家庭', 'home 家庭 内网', Icons.home_outlined),
  HostIconOption(
    'office',
    '办公',
    'office business 办公 企业',
    Icons.business_outlined,
  ),
  HostIconOption(
    'school',
    '教育',
    'school education 教育 学校',
    Icons.school_outlined,
  ),
  HostIconOption('shop', '电商', 'shop store 电商 商店', Icons.storefront_outlined),
  HostIconOption('game', '游戏', 'game 游戏', Icons.sports_esports_outlined),
  HostIconOption('camera', '媒体', 'camera media 媒体 摄像', Icons.videocam_outlined),
  HostIconOption('print', '打印', 'print 打印', Icons.print_outlined),
  HostIconOption('folder', '目录', 'folder 目录 文件夹', Icons.folder_outlined),
  HostIconOption('star', '重点', 'star favorite 重点 收藏', Icons.star_outline),
];

IconData hostIconFor(String key) {
  for (final option in hostIconCatalog) {
    if (option.key == key) return option.icon;
  }
  return Icons.dns_outlined;
}

HostIconOption? hostIconOption(String key) {
  for (final option in hostIconCatalog) {
    if (option.key == key) return option;
  }
  return null;
}

List<HostIconOption> searchHostIcons(String query) {
  final value = query.trim().toLowerCase();
  if (value.isEmpty) return hostIconCatalog;
  return hostIconCatalog
      .where(
        (option) =>
            option.name.toLowerCase().contains(value) ||
            option.key.contains(value) ||
            option.keywords.toLowerCase().contains(value),
      )
      .toList();
}
