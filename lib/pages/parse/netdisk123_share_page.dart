import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../api/netdisk123_client.dart';
import '../../state/app_state.dart';
import '../../state/download_manager.dart';
import '../../state/download_service.dart';
import '../../state/netdisk123_state.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_logger.dart';
import '../../utils/format.dart';
import '../../widgets/empty_view.dart';
import '../../widgets/file_icon.dart';
import '../../widgets/miuix_common.dart';

/// 123 网盘分享解析页（**免登录**）。
///
/// 走 `share/download-list` + `shareDownload/info` 这条通道，只要拿到分享
/// 链接里的 uniID 和提取码就能列出文件、取直链下载，全程不需要账号 token。
class Netdisk123SharePage extends StatefulWidget {
  /// 分享 ID（链接里 /s/ 后面那段）
  final String uniId;

  /// 提取码（可为空）
  final String pwd;

  /// 分享链接原文，仅用于展示
  final String shareUrl;

  const Netdisk123SharePage({
    super.key,
    required this.uniId,
    this.pwd = '',
    this.shareUrl = '',
  });

  @override
  State<Netdisk123SharePage> createState() => _Netdisk123SharePageState();
}

class _Netdisk123SharePageState extends State<Netdisk123SharePage> {
  final _share = Netdisk123Share();
  final _pwdController = TextEditingController();

  String _pwd = '';
  String _parentId = '0';
  final List<(String, String)> _path = [('0', '分享根目录')];

  bool _loading = true;
  bool _downloading = false;
  String _error = '';
  List<Netdisk123File> _files = const [];

  @override
  void initState() {
    super.initState();
    _pwd = widget.pwd;
    _pwdController.text = _pwd;
    _load();
  }

  @override
  void dispose() {
    _pwdController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final files =
          await _share.list(widget.uniId, pwd: _pwd, parentId: _parentId);
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    MiuixToast.show(msg);
  }

  Future<void> _openDir(Netdisk123File f) async {
    setState(() {
      _parentId = f.id;
      _path.add((f.id, f.name));
    });
    await _load();
  }

  Future<void> _back() async {
    if (_path.length <= 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _path.removeLast();
      _parentId = _path.last.$1;
    });
    await _load();
  }

  /// 下载单个文件（或整目录递归）
  Future<int> _downloadFiles(List<Netdisk123File> items) async {
    final app = AppState.I;
    final base = await app.effectiveDownloadDir();
    var added = 0;
    for (final f in items) {
      if (f.isDir) {
        try {
          final sub = await _share.list(widget.uniId,
              pwd: _pwd, parentId: f.id);
          final path = '$base/${f.name}';
          final n = await _downloadInto(sub, path);
          added += n;
        } catch (e) {
          AppLogger.I.e('netdisk123', '展开目录失败 ${f.name}: $e');
        }
        continue;
      }
      try {
        final url =
            await _share.getDownloadUrl(f, widget.uniId, pwd: _pwd);
        if (url.isEmpty) {
          AppLogger.I.w('netdisk123', '分享直链为空: ${f.name}');
          continue;
        }
        final err = await DownloadService.addDirectUrl(
          url: url,
          fileName: f.name,
          cookie: '',
          path: base,
          maxConnections: app.netdisk123Connections,
          batchTotal: items.length,
          referer: 'https://www.123pan.com/',
          userAgent: Netdisk123Client.ua,
        );
        if (err == null) added++;
      } catch (e) {
        AppLogger.I.e('netdisk123', '分享取直链失败 ${f.name}: $e');
      }
    }
    return added;
  }

  Future<int> _downloadInto(List<Netdisk123File> items, String path) async {
    var added = 0;
    for (final f in items) {
      if (f.isDir) continue;
      try {
        final url = await _share.getDownloadUrl(f, widget.uniId, pwd: _pwd);
        if (url.isEmpty) continue;
        final err = await DownloadService.addDirectUrl(
          url: url,
          fileName: f.name,
          cookie: '',
          path: path,
          batchTotal: items.length,
          referer: 'https://www.123pan.com/',
          userAgent: Netdisk123Client.ua,
        );
        if (err == null) added++;
      } catch (e) {
        AppLogger.I.e('netdisk123', '分享取直链失败 ${f.name}: $e');
      }
    }
    return added;
  }

  Future<void> _downloadAll() async {
    if (_downloading || _files.isEmpty) return;
    setState(() => _downloading = true);
    try {
      final n = await _downloadFiles(_files);
      _toast(n > 0 ? '已加入 $n 个下载任务' : '没有可下载的文件');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _downloadSingle(Netdisk123File file) async {
    setState(() => _downloading = true);
    try {
      final n = await _downloadFiles([file]);
      _toast(n > 0 ? '已加入下载队列' : '取直链失败');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _showFileActions(Netdisk123File file) {
    MiuixActionSheet.show<String>(
      context,
      title: file.name,
      actions: [
        (
          icon: Icons.download_rounded,
          text: '立即下载',
          value: 'download',
          color: null
        ),
        (
          icon: Icons.cloud_download_rounded,
          text: '转存后下载',
          value: 'save_download',
          color: null
        ),
      ],
    ).then((v) {
      if (v == null) return;
      switch (v) {
        case 'download':
          _downloadSingle(file);
        case 'save_download':
          _saveThenDownload(file);
      }
    });
  }

  /// 先转存到自己的网盘，再把转存后的文件加入下载任务
  Future<void> _saveThenDownload(Netdisk123File file) async {
    if (!Netdisk123State.I.isLoggedIn) {
      _toast('请先登录 123 网盘');
      return;
    }
    final client = Netdisk123State.I.client;
    final app = AppState.I;
    try {
      final before = await client.listFiles(Netdisk123Client.rootParentId);
      final beforeIds = before.map((e) => e.id).toSet();
      await client.saveShareFiles(
        shareKey: widget.uniId,
        sharePwd: _pwd,
        files: [file],
      );
      final after = await client.listFiles(Netdisk123Client.rootParentId);
      var saved = after
          .where((e) => !e.isDir && !beforeIds.contains(e.id))
          .toList();
      if (saved.isEmpty) {
        saved =
            after.where((e) => !e.isDir && e.name == file.name).toList();
      }
      if (saved.isEmpty) {
        throw Netdisk123Exception(-1, '转存后在网盘里没有找到该文件');
      }
      saved.sort((a, b) => (int.tryParse(a.id) ?? 0)
          .compareTo(int.tryParse(b.id) ?? 0));
      final target = saved.last;
      final url = await client.getDownloadUrl(target);
      if (url.isEmpty) {
        throw Netdisk123Exception(-1, '未获取到下载地址');
      }
      final base = await app.effectiveDownloadDir();
      final err = await DownloadService.addDirectUrl(
        url: url,
        fileName: target.name,
        cookie: '',
        path: base,
        maxConnections: app.netdisk123Connections,
        batchTotal: 1,
        referer: 'https://www.123pan.com/',
        userAgent: Netdisk123Client.ua,
      );
      if (err != null) throw Netdisk123Exception(-1, err);
      _toast('已转存并加入下载队列');
      DownloadManager.I.startPolling();
    } catch (e) {
      AppLogger.I.e('netdisk123', '转存后下载失败 ${file.name}: $e');
      _toast('转存后下载失败: $e');
    }
  }

  Future<void> _submitPwd() async {
    final v = _pwdController.text.trim();
    if (v.isEmpty) return;
    setState(() => _pwd = v);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final fileCount = _files.where((e) => !e.isDir).length;
    final totalSize = _files
        .where((e) => !e.isDir)
        .fold<int>(0, (s, e) => s + e.size);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(_path.last.$2, overflow: TextOverflow.ellipsis),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _back,
        ),
        actions: [
          if (fileCount > 0)
            IconButton(
              tooltip: '全部下载',
              icon: _downloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_rounded),
              onPressed: _downloading ? null : _downloadAll,
            ),
        ],
      ),
      body: Column(
        children: [
          _header(fileCount, totalSize),
          if (_needsPwd()) _pwdBar(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  bool _needsPwd() => _error.isNotEmpty && _pwd.isEmpty;

  Widget _header(int fileCount, int totalSize) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.link_rounded, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '123 网盘分享 · 免登录 · $fileCount 个文件 · '
              '${formatBytes(totalSize)}',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.accent,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pwdBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _pwdController,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '输入提取码',
              ),
              onSubmitted: (_) => _submitPwd(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _submitPwd,
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return EmptyView(
        icon: Icons.error_outline_rounded,
        text: '分享解析失败',
        subText: _error,
        action: FilledButton(
          onPressed: _load,
          child: const Text('重试'),
        ),
      );
    }
    if (_files.isEmpty) {
      return const EmptyView(
        icon: Icons.folder_open_rounded,
        text: '分享内容为空',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: _files.length,
      itemBuilder: (context, i) {
        final f = _files[i];
        return ListTile(
          leading: FileIcon(isDir: f.isDir, name: f.name),
          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            f.isDir ? '文件夹' : formatBytes(f.size),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: f.isDir
              ? const Icon(Icons.chevron_right)
              : IconButton(
                  icon: const Icon(Icons.more_horiz_rounded),
                  onPressed: () => _showFileActions(f),
                ),
          onTap: f.isDir ? () => _openDir(f) : () => _showFileActions(f),
        );
      },
    );
  }
}
