import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../api/uc_client.dart';
import '../../api/uc_models.dart';
import '../../state/app_state.dart';
import '../../state/download_manager.dart';
import '../../state/download_service.dart';
import '../../state/uc_state.dart';
import '../../utils/app_logger.dart';
import '../../utils/format.dart';
import '../../widgets/empty_view.dart';
import '../../widgets/file_icon.dart';
import '../../widgets/file_list_anim.dart';
import '../../widgets/miuix_common.dart';

/// UC 分享内容浏览页：面包屑导航 + 多选，**直接取直链下载，无需转存**。
class UcSharePage extends StatefulWidget {
  final UcShareSession session;
  final List<UcShareFile> initialFiles;

  const UcSharePage({
    super.key,
    required this.session,
    required this.initialFiles,
  });

  @override
  State<UcSharePage> createState() => _UcSharePageState();
}

class _UcSharePageState extends State<UcSharePage> {
  List<UcShareFile> _files = [];
  String _parentFid = '0';
  String _currentName = '分享内容';
  final List<(String, String)> _crumbs = [('0', '分享内容')];
  bool _loading = false;
  String? _error;

  bool _selectMode = false;
  final Set<String> _selected = {};
  bool _downloading = false;

  UcClient get _client => UcState.I.client;

  @override
  void initState() {
    super.initState();
    _files = widget.initialFiles;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _client.listShare(widget.session, _parentFid);
      if (mounted) {
        setState(() {
          _files = files;
          _loading = false;
        });
      }
    } catch (e) {
      AppLogger.I.e('uc', '分享列表失败: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _enterDir(UcShareFile dir) {
    setState(() {
      _crumbs.add((_parentFid, _currentName));
      _parentFid = dir.fid;
      _currentName = dir.fileName;
      _files = [];
      _loading = true;
      _selectMode = false;
      _selected.clear();
    });
    _load();
  }

  void _toBreadcrumb(int index) {
    if (index >= _crumbs.length - 1) return;
    setState(() {
      _crumbs.removeRange(index + 1, _crumbs.length);
      _parentFid = _crumbs.last.$1;
      _currentName = _crumbs.last.$2;
      _files = [];
      _error = null;
      _selectMode = false;
      _selected.clear();
    });
    _load();
  }

  // ---------------- 多选下载 ----------------

  void _enterSelectMode(UcShareFile file) {
    setState(() {
      _selectMode = true;
      _selected.add(file.fid);
    });
  }

  void _toggleSelect(UcShareFile file) {
    setState(() {
      if (!_selected.remove(file.fid)) {
        _selected.add(file.fid);
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  Future<void> _batchDownload() async {
    if (_selected.isEmpty || _downloading) return;
    setState(() => _downloading = true);
    _toast('正在展开选中内容…');
    try {
      final items = await _expandSelection(_selected);
      if (items.isEmpty) {
        _toast('没有可下载的文件');
        return;
      }
      final added = await _downloadFileList(items);
      if (added == 0) {
        _toast('没有成功添加下载任务');
      } else {
        _toast('已添加 $added 个下载任务（未转存）');
        DownloadManager.I.startPolling();
        _exitSelectMode();
      }
    } catch (e) {
      AppLogger.I.e('uc', '分享批量下载失败: $e');
      _toast('批量下载失败: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// 展开选中项为 (分享文件, 相对路径)
  Future<List<(UcShareFile, String)>> _expandSelection(
      Set<String> selected) async {
    final result = <(UcShareFile, String)>[];
    for (final f in _files) {
      if (!selected.contains(f.fid)) continue;
      if (f.isDir) {
        result.addAll(await _collectFiles(f.fid, '${f.fileName}/'));
      } else {
        result.add((f, ''));
      }
    }
    return result;
  }

  Future<List<(UcShareFile, String)>> _collectFiles(String fid, String relPath,
      {int depth = 0}) async {
    if (depth > 8) return [];
    final files = await _client.listShare(widget.session, fid);
    final result = <(UcShareFile, String)>[];
    for (final f in files) {
      if (result.length >= 500) break;
      if (f.isDir) {
        result.addAll(
            await _collectFiles(f.fid, '$relPath${f.fileName}/', depth: depth + 1));
      } else {
        result.add((f, relPath));
      }
    }
    return result;
  }

  /// 分批取分享直链并加入下载队列（每批 50 个）
  Future<int> _downloadFileList(List<(UcShareFile, String)> items) async {
    final app = AppState.I;
    final base = await app.effectiveDownloadDir();
    var added = 0;
    const batchSize = 50;
    final total = items.length;
    for (var i = 0; i < items.length; i += batchSize) {
      final end =
          (i + batchSize) > items.length ? items.length : (i + batchSize);
      final batch = items.sublist(i, end);
      final (infos, cookie) = await _client.getShareDownloadInfo(
          widget.session, batch.map((e) => e.$1).toList());
      final relByFid = {for (final e in batch) e.$1.fid: e.$2};
      for (final info in infos) {
        if (info.url.isEmpty) continue;
        final rel = relByFid[info.fid] ?? '';
        final path = rel.isEmpty ? base : '$base/$rel';
        final err = await DownloadService.addDirectUrl(
          url: info.url,
          fileName: info.fileName,
          path: path,
          cookie: cookie,
          batchTotal: total,
          maxConnections: app.ucConnections,
          referer: UcClient.referer,
          userAgent: UcClient.uaPc,
        );
        if (err == null) added++;
      }
    }
    return added;
  }

  void _downloadSingle(UcShareFile file) async {
    try {
      final (infos, cookie) =
          await _client.getShareDownloadInfo(widget.session, [file]);
      if (infos.isEmpty || infos.first.url.isEmpty) {
        throw Exception('未获取到下载地址');
      }
      final info = infos.first;
      final base = await AppState.I.effectiveDownloadDir();
      final err = await DownloadService.addDirectUrl(
        url: info.url,
        fileName: info.fileName.isNotEmpty ? info.fileName : file.fileName,
        cookie: cookie,
        path: base,
        batchTotal: 1,
        maxConnections: AppState.I.ucConnections,
        referer: UcClient.referer,
        userAgent: UcClient.uaPc,
      );
      if (err != null) throw Exception(err);
      _toast('已加入下载队列（未转存）');
      DownloadManager.I.startPolling();
    } catch (e) {
      AppLogger.I.e('uc', '分享下载失败 ${file.fileName}: $e');
      _toast('下载失败: $e');
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: 'UC 分享',
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: MiuixIcon(
              icon: Icons.arrow_back_ios_new_rounded,
              tint: colors.onSurfaceContainer,
              size: 20),
        ),
        actions: [
          MiuixIconButton(
            onPressed: _load,
            child: MiuixIcon(icon: Icons.refresh_rounded, tint: colors.primary),
          ),
        ],
      ),
      content: (padding) => Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_crumbs.length > 1) _buildBreadcrumb(colors),
            Expanded(child: _buildBody()),
            if (_selectMode) _buildSelectBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumb(MiuixColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < _crumbs.length; i++) ...[
              if (i > 0)
                MiuixIcon(
                    icon: Icons.chevron_right_rounded,
                    size: 16,
                    tint: colors.onSurfaceSecondary),
              MiuixPressable(
                onPressed: () => _toBreadcrumb(i),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: MiuixText(
                    _crumbs[i].$2,
                    fontSize: 13,
                    color: i == _crumbs.length - 1
                        ? colors.primary
                        : colors.onSurfaceSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSelectBar() {
    final count = _selected.length;
    final colors = MiuixTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(top: BorderSide(color: colors.dividerLine, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            MiuixText('已选 $count 项',
                fontSize: 14, color: colors.onSurfaceContainer),
            const Spacer(),
            MiuixButton(
              onPressed: _downloading || count == 0 ? null : _batchDownload,
              colors: MiuixButtonColors(
                color: colors.primary,
                disabledColor: colors.primaryVariant,
                contentColor: Colors.white,
                disabledContentColor: Colors.white,
              ),
              child: MiuixLoadingSwitcher(
                loading: _downloading,
                child: MiuixText('下载($count)', color: Colors.white, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null && _files.isEmpty) {
      return BodySwitcher(
        child: EmptyView(
          icon: Icons.cloud_off_rounded,
          text: '加载失败',
          subText: _error,
          action: MiuixTextButton('重试', onPressed: _load),
        ),
      );
    }
    if (_loading && _files.isEmpty) {
      return BodySwitcher(
          child: const Center(child: MiuixCircularProgressIndicator()));
    }
    if (_files.isEmpty) {
      return BodySwitcher(
          child: const EmptyView(
              icon: Icons.folder_open_rounded, text: '分享里没有文件'));
    }
    final content = MiuixPullToRefresh(
      isRefreshing: _loading,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _files.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) =>
            StaggeredFileItem(index: i, child: _buildItem(_files[i])),
      ),
    );
    return BodySwitcher(child: content);
  }

  Widget _buildItem(UcShareFile file) {
    final selected = _selected.contains(file.fid);
    final colors = MiuixTheme.of(context).colors;
    return MiuixCard(
      onPressed: () {
        if (_selectMode) {
          _toggleSelect(file);
        } else if (file.isDir) {
          _enterDir(file);
        } else {
          _showFileActions(file);
        }
      },
      onLongPress: _selectMode ? null : () => _enterSelectMode(file),
      child: Container(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            FileIcon(isDir: file.isDir, name: file.fileName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MiuixText(
                    file.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    color: colors.onSurfaceContainer,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  const SizedBox(height: 4),
                  MiuixText(
                    file.isDir ? '文件夹' : formatBytes(file.size),
                    color: colors.onSurfaceSecondary,
                    fontSize: 12,
                  ),
                ],
              ),
            ),
            if (_selectMode)
              MiuixIcon(
                icon: selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                tint: selected ? colors.primary : colors.onSurfaceSecondary,
                size: 22,
              )
            else
              MiuixIcon(
                  icon: Icons.chevron_right_rounded,
                  tint: colors.onSurfaceSecondary,
                  size: 20),
          ],
        ),
      ),
    );
  }

  void _showFileActions(UcShareFile file) {
    MiuixActionSheet.show<String>(
      context,
      title: file.fileName,
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
  Future<void> _saveThenDownload(UcShareFile file) async {
    if (!UcState.I.isLoggedIn) {
      _toast('请先登录 UC 网盘');
      return;
    }
    final client = _client;
    try {
      final before = await client.listFiles(UcClient.rootFid);
      final beforeIds = before.map((e) => e.fid).toSet();
      await client.saveShare(widget.session, [file], UcClient.rootFid);
      final after = await client.listFiles(UcClient.rootFid);
      var saved = after
          .where((e) => !e.isDir && !beforeIds.contains(e.fid))
          .toList();
      if (saved.isEmpty) {
        saved = after
            .where((e) => !e.isDir && e.fileName == file.fileName)
            .toList();
      }
      if (saved.isEmpty) {
        throw UcException(-1, '转存后在网盘里没有找到该文件');
      }
      saved.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      final target = saved.last;
      final (infos, cookie) = await client.getDownloadInfo([target.fid]);
      if (infos.isEmpty || infos.first.url.isEmpty) {
        throw UcException(-1, '未获取到下载地址');
      }
      final info = infos.first;
      final base = await AppState.I.effectiveDownloadDir();
      final err = await DownloadService.addDirectUrl(
        url: info.url,
        fileName:
            info.fileName.isNotEmpty ? info.fileName : file.fileName,
        cookie: cookie,
        path: base,
        batchTotal: 1,
        maxConnections: AppState.I.ucConnections,
        referer: UcClient.referer,
        userAgent: UcClient.uaPc,
      );
      if (err != null) throw UcException(-1, err);
      _toast('已转存并加入下载队列');
      DownloadManager.I.startPolling();
    } catch (e) {
      AppLogger.I.e('uc', '转存后下载失败 ${file.fileName}: $e');
      _toast('转存后下载失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    MiuixToast.show(msg);
  }
}
