import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/download_service.dart';
import '../widgets/miuix_common.dart';

/// 平台对应的安装包（latest.json 里的 assets 条目）
class UpdateAsset {
  final String name;
  final Uri url;
  final String sha256;

  const UpdateAsset({required this.name, required this.url, this.sha256 = ''});
}

class AppUpdate {
  final String version;
  final Uri releaseUrl;
  final String notes;

  /// 当前平台可用的安装包；没有匹配到时为 null（只能打开下载页）
  final UpdateAsset? asset;

  const AppUpdate({
    required this.version,
    required this.releaseUrl,
    required this.notes,
    this.asset,
  });
}

/// 检查更新：读取 Release 附带的 `latest.json`（不依赖 GitHub API，避免匿名限流 403）。
///
/// 直连 `https://github.com/<repo>/releases/latest/download/latest.json`，
/// 失败再走 `https://gh.ifeng369.top/<原始链接>` 代理。
class UpdateChecker {
  UpdateChecker._();

  /// 版本号：优先由构建注入（CI 用 --dart-define=APP_VERSION=1.3.10），
  /// 本地直接运行时回退到下方默认值（需与 pubspec.yaml 的 version 保持一致）
  static const currentVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.3.16',
  );

  static const repo = 'ifeng369/fast-downloader';

  /// GitHub 加速代理前缀（下载/取清单时拼在原始 URL 前面）
  static const proxyPrefix = 'https://gh.ifeng369.top/';

  /// 代理地址：https://gh.ifeng369.top/<原始 URL>
  static Uri proxyUrl(Uri url) => Uri.parse('$proxyPrefix${url.toString()}');

  static final Uri _latestJsonUrl = Uri.parse(
    'https://github.com/$repo/releases/latest/download/latest.json',
  );

  /// 最近一次检查失败的原因（手动检查时展示，避免把失败伪装成“已是最新”）
  static String? lastError;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: const {'User-Agent': 'fast-downloader-update-checker'},
    ),
  );

  static Future<AppUpdate?> check() async {
    lastError = null;
    // 先直连，失败再走代理；两者都是静态文件，不消耗 GitHub API 配额
    String? body;
    for (final url in [_latestJsonUrl, proxyUrl(_latestJsonUrl)]) {
      body = await _fetchText(url);
      if (body != null) break;
    }
    if (body == null) {
      lastError ??= '无法连接 GitHub 或代理，请检查网络';
      return null;
    }
    final info = parseLatestJson(body);
    if (info == null) {
      lastError = 'latest.json 内容不正确';
      return null;
    }
    if (!_isNewer(info.version, currentVersion)) return null;
    return info;
  }

  static Future<String?> _fetchText(Uri url) async {
    try {
      final resp = await _dio.get<dynamic>(
        url.toString(),
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 400,
        ),
      );
      final data = resp.data;
      return data is String ? data : jsonEncode(data);
    } on DioException catch (e) {
      lastError = '获取 latest.json 失败（${e.response?.statusCode ?? e.type.name}）';
      return null;
    } catch (e) {
      lastError = '获取 latest.json 失败: $e';
      return null;
    }
  }

  /// latest.json 结构：
  /// ```json
  /// {"version":"1.3.10","notes":"...","assets":[{"name":"...","url":"...","sha256":"..."}]}
  /// ```
  static AppUpdate? parseLatestJson(String body) {
    try {
      final data = jsonDecode(body);
      if (data is! Map) return null;
      final version = _normalize(
        (data['version'] ?? data['tag'] ?? '').toString(),
      );
      if (version == null) return null;
      final notes = (data['notes'] ?? data['body'] ?? '').toString().trim();
      return AppUpdate(
        version: version,
        releaseUrl: Uri.parse(
          'https://github.com/$repo/releases/tag/v$version',
        ),
        notes: notes,
        asset: pickAsset(data['assets']),
      );
    } catch (_) {
      return null;
    }
  }

  /// 从 assets 里挑出当前平台的安装包：
  /// - Windows：`*.zip`（优先名字带 windows）
  /// - Android：`*.apk`（优先 arm64-v8a）
  static UpdateAsset? pickAsset(dynamic assets) {
    final items = <UpdateAsset>[];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] ?? '').toString();
        final url = Uri.tryParse(
          (a['url'] ?? a['browser_download_url'] ?? '').toString(),
        );
        if (name.isEmpty || url == null || !url.hasScheme) continue;
        items.add(
          UpdateAsset(
            name: name,
            url: url,
            sha256: (a['sha256'] ?? '').toString(),
          ),
        );
      }
    }
    if (items.isEmpty || kIsWeb) return null;
    String lower(UpdateAsset a) => a.name.toLowerCase();
    if (Platform.isAndroid) {
      final apks = items.where((a) => lower(a).endsWith('.apk')).toList();
      if (apks.isEmpty) return null;
      final arm64 = apks.where((a) => lower(a).contains('arm64')).toList();
      return arm64.isNotEmpty ? arm64.first : apks.first;
    }
    if (Platform.isWindows) {
      final zips = items.where((a) => lower(a).endsWith('.zip')).toList();
      if (zips.isEmpty) return null;
      final win = zips.where((a) => lower(a).contains('windows')).toList();
      return win.isNotEmpty ? win.first : zips.first;
    }
    return null;
  }

  static const _skippedVersionKey = 'update_skipped_version';

  /// 正在检查/弹窗中：防止连点导致重复请求与弹窗叠加
  static bool _inFlight = false;

  static Future<void> checkAndPrompt(
    BuildContext context, {
    bool manual = false,
  }) async {
    if (_inFlight) return;
    _inFlight = true;
    var loadingShown = false;
    try {
      if (manual) {
        // 手动检查：先把「检查更新中…」显示出来，避免点了没反应
        unawaited(
          MiuixOverlayPanel.show(
            context: context,
            builder: (_) => const _UpdateLoadingDialog(),
          ).catchError((Object _) {}),
        );
        loadingShown = true;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      final update = await check();
      if (loadingShown) {
        MiuixOverlayPanel.hide();
        loadingShown = false;
        // 等浮层移除动画，避免紧接着的选择弹窗被一起关掉
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (!context.mounted) return;
      if (update == null) {
        if (manual) {
          final err = lastError;
          MiuixToast.show(err == null ? '当前已是最新版本' : '检查更新失败：$err');
        }
        return;
      }
      if (!manual && await _isSkipped(update.version)) return;
      final notes = update.notes.isEmpty ? '' : '\n\n${update.notes}';
      final asset = update.asset;
      final choice = await miuixChoiceDialog<String>(
        context,
        title: '发现新版本 ${update.version}',
        options: [
          if (asset != null) 'direct',
          if (asset != null) 'proxy',
          'open',
          'later',
          'skip',
        ],
        current: asset != null ? 'direct' : 'open',
        labelOf: (value) => switch (value) {
          'direct' => '直接下载（加入下载任务）',
          'proxy' => '代理下载（gh.ifeng369.top 加速）',
          'open' => '打开 GitHub 下载页',
          'skip' => '此次更新不再提醒',
          _ => '稍后提醒',
        },
        hint: '当前版本 $currentVersion$notes',
      );
      switch (choice) {
        case 'skip':
          await _saveSkipped(update.version);
        case 'open':
          await launchUrl(
            update.releaseUrl,
            mode: LaunchMode.externalApplication,
          );
        case 'direct':
        case 'proxy':
          final target = update.asset;
          if (target == null) return;
          final viaProxy = choice == 'proxy';
          var err = await DownloadService.addDirectUrl(
            url: (viaProxy ? proxyUrl(target.url) : target.url).toString(),
            fileName: target.name,
            cookie: '',
            referer: 'https://github.com/',
            // gh 代理不实现 Range（Range 请求仍返回 200 全量），
            // 多线程分块会失败 → 代理下载强制单连接
            connections: viaProxy ? 1 : null,
            maxConnections: viaProxy ? 1 : null,
          );
          if (viaProxy && err != null) {
            // 代理不可用/不稳定：自动回退直连
            err = await DownloadService.addDirectUrl(
              url: target.url.toString(),
              fileName: target.name,
              cookie: '',
              referer: 'https://github.com/',
            );
            MiuixToast.show(err == null ? '代理不可用，已改用直连下载：${target.name}' : err);
            return;
          }
          MiuixToast.show(err == null ? '已加入下载任务：${target.name}' : err);
      }
    } finally {
      if (loadingShown) MiuixOverlayPanel.hide();
      _inFlight = false;
    }
  }

  static Future<bool> _isSkipped(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_skippedVersionKey) == version;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _saveSkipped(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_skippedVersionKey, version);
    } catch (_) {}
  }

  static String? _normalize(String raw) {
    final value = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(value);
    return match == null ? null : '${match[1]}.${match[2]}.${match[3]}';
  }

  static bool _isNewer(String candidate, String current) {
    final a = candidate.split('.').map(int.parse).toList();
    final b = current.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }
}

/// 手动检查更新时的加载浮层（不可点击关闭）
class _UpdateLoadingDialog extends StatelessWidget {
  const _UpdateLoadingDialog();

  @override
  Widget build(BuildContext context) {
    return MiuixOverlayDialog(
      show: true,
      content: MiuixDismissScope(
        onDismissRequest: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: MiuixCircularProgressIndicator(size: 20, strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              MiuixText('检查更新中…', fontSize: 14),
            ],
          ),
        ),
      ),
    );
  }
}
