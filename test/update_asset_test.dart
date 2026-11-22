import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quarklite/core/update_checker.dart';

void main() {
  const assets = [
    {
      'name': 'fast-downloader-arm64-v8a.apk',
      'browser_download_url':
          'https://github.com/ifeng369/fast-downloader/releases/download/v9/fast-downloader-arm64-v8a.apk',
    },
    {
      'name': 'fast-downloader-windows-x64.zip',
      'browser_download_url':
          'https://github.com/ifeng369/fast-downloader/releases/download/v9/fast-downloader-windows-x64.zip',
    },
    {'name': 'checksums.txt', 'browser_download_url': 'not-a-url'},
  ];

  test('pickAsset 按平台挑安装包（Windows 取 zip）', () {
    final asset = UpdateChecker.pickAsset(assets);
    expect(asset, isNotNull);
    if (Platform.isWindows) {
      expect(asset!.name, 'fast-downloader-windows-x64.zip');
      expect(asset.url.path, endsWith('/fast-downloader-windows-x64.zip'));
    }
  });

  test('pickAsset 忽略没有直链的条目与空列表', () {
    expect(UpdateChecker.pickAsset([]), isNull);
    expect(UpdateChecker.pickAsset(null), isNull);
    expect(
      UpdateChecker.pickAsset([
        {'name': 'x.zip', 'browser_download_url': ''},
      ]),
      isNull,
    );
  });

  test('proxyUrl 拼在 gh 代理前缀后', () {
    final uri = UpdateChecker.proxyUrl(
      Uri.parse('https://github.com/a/b/releases/download/v1/c.zip'),
    );
    expect(uri.toString(),
        'https://gh.ifeng369.top/https://github.com/a/b/releases/download/v1/c.zip');
  });
}
