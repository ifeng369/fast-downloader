import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/download_service.dart';
import '../widgets/miuix_common.dart';

/// 平台对应的安装包（Release asset）
class UpdateAsset {
  final String name;
  final Uri url;

  const UpdateAsset({required this.name, required this.url});
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

class UpdateChecker {
  UpdateChecker._();

  /// 版本号：优先由构建注入（CI 用 --dart-define=APP_VERSION=1.3.3），
  /// 本地直接运行时回退到下方默认值（需与 pubspec.yaml 的 version 保持一致）
  static const currentVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.3.10');

  static const repo = 'ifeng369/fast-downloader';

  /// 轻量探测：/releases/latest 会 302 到 /releases/tag/vX.Y.Z，不消耗 API 限流
  static const _latestPageUrl = 'https://github.com/$repo/releases/latest';

  /// 兜底：GitHub API（匿名 60 次/小时/IP，容易 403）
  static const _latestApiUrl =
      'https://api.github.com/repos/$repo/releases/latest';

  /// 最近一次检查失败的原因（手动检查时展示，避免把失败伪装成“已是最新”）
  static String? lastError;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    headers: const {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'fast-downloader-update-checker',
    },
  ));

  static Future<AppUpdate?> check() async {
    lastError = null;
    final viaRedirect = await _checkViaRedirect();
    if (viaRedirect != null) return viaRedirect;
    return _checkViaApi();
  }

  /// 1) 跟随 /releases/latest 的 302 拿到最新 tag（无 API 限流）
  /// 注：asset 直接按固定文件名拼下载地址（CI 产物名固定）
  static Future<AppUpdate?> _checkViaRedirect() async {
    try {
      final resp = await _dio.get<dynamic>(
        _latestPageUrl,
        options: Options(followRedirects: false, validateStatus: (_) => true),
      );
      final version = versionFromLocation(
          resp.headers.value('location') ?? '');
      if (version == null) {
        lastError = '无法解析最新版本（HTTP ${resp.statusCode}）';
        return null;
      }
      if (!_isNewer(version, currentVersion)) return null;
      return AppUpdate(
        version: version,
        releaseUrl: Uri.parse('https://github.com/$repo/releases/tag/v$version'),
        notes: '',
        asset: assetForVersion(version),
      );
    } catch (e) {
      lastError = '网络错误: $e';
      return null;
    }
  }

  /// 2) 兜底走 GitHub API，可额外拿到更新说明与真实 asset 列表
  static Future<AppUpdate?> _checkViaApi() async {
    try {
      final response = await _dio.get<dynamic>(_latestApiUrl);
      final data = response.data;
      if (data is! Map) return null;
      final tag = data['tag_name']?.toString() ?? '';
      final version = _normalize(tag);
      final url = Uri.tryParse(data['html_url']?.toString() ?? '');
      if (version == null || url == null || !url.hasScheme) return null;
      if (!_isNewer(version, currentVersion)) return null;
      return AppUpdate(
        version: version,
        releaseUrl: url,
        notes: data['body']?.toString().trim() ?? '',
        asset: pickAsset(data['assets']),
      );
    } on DioException catch (e) {
      lastError = e.response?.statusCode == 403
          ? 'GitHub API 限流（匿名 60 次/小时），请稍后再试'
          : '检查失败: ${e.message}';
      return null;
    } catch (e) {
      lastError ??= '检查失败: $e';
      return null;
    }
  }

  /// 从 302 Location（.../releases/tag/v1.3.10）解析版本号
  static String? versionFromLocation(String location) {
    final match = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(location);
    return match == null ? null : _normalize(match.group(1)!);
  }

  /// 按固定产物名拼 asset 下载地址（与 CI 发布命名保持一致）
  static UpdateAsset? assetForVersion(String version) {
    if (kIsWeb) return null;
    final base = 'https://github.com/$repo/releases/download/v$version';
    if (Platform.isWindows) {
      const name = 'fast-downloader-windows-x64.zip';
      return UpdateAsset(name: name, url: Uri.parse('$base/$name'));
    }
    if (Platform.isAndroid) {
      const name = 'fast-downloader-arm64-v8a.apk';
      return UpdateAsset(name: name, url: Uri.parse('$base/$name'));
    }
    return null;
  }

  /// GitHub 加速代理前缀（下载时拼在原始 URL 前面）
  static const proxyPrefix = 'https://gh.ifeng369.top/';

  /// 代理下载地址：https://gh.ifeng369.top/<原始 URL>
  static Uri proxyUrl(Uri asset) => Uri.parse('$proxyPrefix${asset.toString()}');

  /// 从 Release 的 assets 里挑出当前平台的安装包：
  /// - Windows：`*.zip`（优先名字带 windows）
  /// - Android：`*.apk`（优先 arm64-v8a）
  static UpdateAsset? pickAsset(dynamic assets) {
    final items = <UpdateAsset>[];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] ?? '').toString();
        final url = Uri.tryParse((a['browser_download_url'] ?? '').toString());
        if (name.isEmpty || url == null || !url.hasScheme) continue;
        items.add(UpdateAsset(name: name, url: url));
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

  static Future<void> checkAndPrompt(
    BuildContext context, {
    bool manual = false,
  }) async {
    final update = await check();
    if (!context.mounted) return;
    if (update == null) {
      if (manual) {
        final err = lastError;
        MiuixToast.show(
            err == null ? '当前已是最新版本' : '检查更新失败：$err');
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
        await launchUrl(update.releaseUrl,
            mode: LaunchMode.externalApplication);
      case 'direct':
      case 'proxy':
        final target = update.asset;
        if (target == null) return;
        final url = choice == 'proxy' ? proxyUrl(target.url) : target.url;
        final err = await DownloadService.addDirectUrl(
          url: url.toString(),
          fileName: target.name,
          cookie: '',
          referer: 'https://github.com/',
        );
        MiuixToast.show(err == null ? '已加入下载任务：${target.name}' : err);
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
