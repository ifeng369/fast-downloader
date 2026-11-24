/// 直链 / GitHub 链接识别工具（解析页与下载管理共用）
library;

/// GitHub 下载域名（分享来的链接直接入队）
const _githubHosts = <String>[
  'github.com',
  'www.github.com',
  'raw.githubusercontent.com',
  'codeload.github.com',
  'objects.githubusercontent.com',
  'gist.githubusercontent.com',
  'gist.github.com',
];

/// 能直接当文件下载的扩展名（用于识别普通直链）
const _directExts = <String>[
  '.zip', '.apk', '.exe', '.7z', '.rar', '.tar', '.gz', '.tgz', '.xz',
  '.bz2', '.mp4', '.mkv', '.avi', '.mov', '.flv', '.webm', '.mp3', '.flac',
  '.wav', '.pdf', '.iso', '.dmg', '.msi', '.deb', '.rpm', '.jar', '.torrent',
];

bool isGithubUrl(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  // 已经是自己的加速代理地址，不再重复代理
  if (host == 'gh.ifeng369.top') return false;
  return _githubHosts.contains(host) || host.endsWith('.githubusercontent.com');
}

bool isDirectFileUrl(String url) {
  if (isGithubUrl(url)) return true;
  final path = Uri.tryParse(url.trim())?.path.toLowerCase() ?? '';
  return _directExts.any(path.endsWith);
}

/// 从 URL 末段取文件名
String fileNameOfUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  final segs = (uri?.pathSegments ?? const <String>[])
      .where((s) => s.isNotEmpty)
      .toList();
  var name = segs.isEmpty ? '' : segs.last;
  try {
    name = Uri.decodeComponent(name);
  } catch (_) {}
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return name.isEmpty ? 'download' : name;
}
