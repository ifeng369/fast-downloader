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
      String.fromEnvironment('APP_VERSION', defaultValue: '1.3.5');

  /// 自动更新检查指向本项目（fork）的 Release
  static const _latestReleaseUrl =
      'https://api.github.com/repos/ifeng369/fast-downloader/releases/latest';
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    headers: const {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'fast-downloader-update-checker',
    },
  ));

  static Future<AppUpdate?> check() async {
    try {
      final response = await _dio.get<dynamic>(_latestReleaseUrl);
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
    } catch (_) {
      return null;
    }
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
      if (manual) MiuixToast.show('当前已是最新版本');
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
