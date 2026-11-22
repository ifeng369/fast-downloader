import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quarklite/core/update_checker.dart';

void main() {
  const assets = [
    {
      'name': 'fast-downloader-arm64-v8a.apk',
      'url':
          'https://github.com/ifeng369/fast-downloader/releases/download/v9/fast-downloader-arm64-v8a.apk',
      'sha256': 'aa',
    },
    {
      'name': 'fast-downloader-windows-x64.zip',
      'url':
          'https://github.com/ifeng369/fast-downloader/releases/download/v9/fast-downloader-windows-x64.zip',
      'sha256': 'bb',
    },
  ];

  test('pickAsset 按平台挑安装包（Windows 取 zip）', () {
    final asset = UpdateChecker.pickAsset(assets);
    expect(asset, isNotNull);
    if (Platform.isWindows) {
      expect(asset!.name, 'fast-downloader-windows-x64.zip');
      expect(asset.url.path, endsWith('/fast-downloader-windows-x64.zip'));
      expect(asset.sha256, 'bb');
    }
  });

  test('pickAsset 忽略没有直链的条目与空列表', () {
    expect(UpdateChecker.pickAsset([]), isNull);
    expect(UpdateChecker.pickAsset(null), isNull);
    expect(
      UpdateChecker.pickAsset([
        {'name': 'x.zip', 'url': ''},
      ]),
      isNull,
    );
  });

  test('parseLatestJson 解析版本与资产', () {
    final info = UpdateChecker.parseLatestJson(jsonEncode({
      'version': 'v9.9.9',
      'notes': '修复若干问题',
      'assets': assets,
    }));
    expect(info, isNotNull);
    expect(info!.version, '9.9.9');
    expect(info.notes, '修复若干问题');
    expect(info.releaseUrl.toString(),
        'https://github.com/ifeng369/fast-downloader/releases/tag/v9.9.9');
    expect(info.asset, isNotNull);
  });

  test('parseLatestJson 拒绝无效内容', () {
    expect(UpdateChecker.parseLatestJson(''), isNull);
    expect(UpdateChecker.parseLatestJson('not json'), isNull);
    expect(UpdateChecker.parseLatestJson('{"version":""}'), isNull);
  });

  test('proxyUrl 拼在 gh 代理前缀后', () {
    final uri = UpdateChecker.proxyUrl(
      Uri.parse('https://github.com/a/b/releases/download/v1/c.zip'),
    );
    expect(uri.toString(),
        'https://gh.ifeng369.top/https://github.com/a/b/releases/download/v1/c.zip');
  });
}
