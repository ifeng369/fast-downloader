import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/gopeed/gopeed_boot.dart';
import '../core/gopeed/gopeed_models.dart';
import '../state/app_state.dart';
import '../utils/app_logger.dart';
import '../utils/window_close.dart';
import '../widgets/miuix_common.dart';

/// 自动更新：记录「更新包已加入下载队列」，等下载完成后再自动安装。
///
/// - Android：调用系统安装器（首次会跳「安装未知应用」授权页，返回后自动重试）
/// - Windows：启动一个脱离应用生命周期的 PowerShell 脚本，等本进程退出后
///   把 zip 解压覆盖到当前程序目录，然后重新拉起程序
class AutoUpdater {
  AutoUpdater._();

  static const _kFile = 'update_pending_file';
  static const _kVersion = 'update_pending_version';

  static String? _pendingFile;
  static String? _pendingVersion;
  static bool _loaded = false;

  /// 当前运行版本，用于避免把「已安装的版本」再装一遍
  static String _currentVersion = '';

  /// 防止一轮轮询里重复触发安装
  static bool _busy = false;

  /// Android：等用户授予「安装未知应用」后，回到前台重试的安装包路径
  static String? _retryPath;

  /// 读取持久化的待安装记录（应用重启后仍能续上）
  static Future<void> init({String? currentVersion}) async {
    if (currentVersion != null && currentVersion.isNotEmpty) {
      _currentVersion = currentVersion;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _pendingFile = prefs.getString(_kFile);
      _pendingVersion = prefs.getString(_kVersion);
      if (_pendingFile != null) {
        AppLogger.I.i('update', '待安装更新包: $_pendingFile（$_pendingVersion）');
      }
    } catch (e) {
      AppLogger.I.w('update', '读取待安装记录失败: $e');
    }
    _loaded = true;
  }

  /// 是否有同一版本的更新包等待下载/安装（避免每次启动重复弹窗）
  static bool isPendingVersion(String version) =>
      _pendingVersion != null && _pendingVersion == version;

  /// 更新包已加入下载队列
  static Future<void> markPending({
    required String version,
    required String fileName,
  }) async {
    _pendingFile = fileName;
    _pendingVersion = version;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kFile, fileName);
      await prefs.setString(_kVersion, version);
    } catch (e) {
      AppLogger.I.w('update', '保存待安装记录失败: $e');
    }
  }

  static Future<void> clearPending() async {
    _pendingFile = null;
    _pendingVersion = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kFile);
      await prefs.remove(_kVersion);
    } catch (_) {}
  }

  /// 下载轮询回调：发现更新包下载完成就执行安装
  static Future<void> onTasks(List<GopeedTask> tasks) async {
    if (!_loaded) {
      unawaited(init());
      return;
    }
    final file = _pendingFile;
    if (file == null || _busy) return;
    // 待安装的版本已经装上了：清掉标记，避免重复安装/降级
    if (_currentVersion.isNotEmpty && _pendingVersion == _currentVersion) {
      AppLogger.I.i('update', '待安装版本 $_pendingVersion 已是当前版本，清除标记');
      await clearPending();
      return;
    }
    for (final task in tasks) {
      if (task.status != GopeedStatus.done) continue;
      if (!_matches(task, file)) {
        AppLogger.I.i(
          'update',
          '已完成任务不匹配更新包: name=${task.name} path=${task.filePath}（等待 $file）',
        );
        continue;
      }
      _busy = true;
      try {
        final path = await _resolvePath(task, file);
        if (path == null) {
          AppLogger.I.w('update', '更新包已下载但找不到文件: $file');
          await clearPending();
          return;
        }
        // 先清标记，避免安装被取消后每轮轮询都重复拉起
        await clearPending();
        await _install(path);
      } catch (e) {
        AppLogger.I.e('update', '自动安装失败: $e');
        MiuixToast.show('自动安装失败：$e');
      } finally {
        _busy = false;
      }
      return;
    }
  }

  /// 从系统设置页返回后，重试因权限被中断的安装
  static Future<void> retryPendingInstall() async {
    final path = _retryPath;
    if (path == null) return;
    _retryPath = null;
    if (!File(path).existsSync()) return;
    await _install(path);
  }

  /// 去掉 Gopeed 为重名文件自动追加的 " (2)" 后缀
  static String _stripCopySuffix(String name) {
    var out = name;
    while (true) {
      final next = out.replaceFirst(RegExp(r'\s*\(\d+\)$'), '');
      if (next == out) return out;
      out = next;
    }
  }

  static bool _matches(GopeedTask task, String file) {
    if (task.name == file) return true;
    final p = task.filePath.replaceAll('\\', '/');
    if (p.isNotEmpty && (p == file || p.endsWith('/$file'))) return true;
    // Gopeed 遇到同名文件会存成 "xxx (2).zip"，任务名也会跟着变
    final target = _stripCopySuffix(file).toLowerCase();
    final candidates = <String>[task.name];
    if (p.isNotEmpty) candidates.add(p.split('/').last);
    for (final c in candidates) {
      if (c.isEmpty) continue;
      if (_stripCopySuffix(c).toLowerCase() == target) return true;
    }
    return false;
  }

  static Future<String?> _resolvePath(GopeedTask task, String file) async {
    final direct = task.filePath;
    if (direct.isNotEmpty && await File(direct).exists()) return direct;
    final dir = await AppState.I.effectiveDownloadDir();
    final guess = '$dir${Platform.pathSeparator}$file';
    if (await File(guess).exists()) return guess;
    final byName = '$dir${Platform.pathSeparator}${task.name}';
    if (await File(byName).exists()) return byName;
    // 兜底：下载目录里按「主名 + 扩展名」找最新的一个（含 " (1)" 之类后缀）
    try {
      final d = Directory(dir);
      if (await d.exists()) {
        final target = _stripCopySuffix(file).toLowerCase();
        String? best;
        DateTime? bestAt;
        await for (final e in d.list()) {
          if (e is! File) continue;
          final n = e.path.split(Platform.pathSeparator).last;
          if (_stripCopySuffix(n).toLowerCase() != target) continue;
          final m = (await e.stat()).modified;
          if (bestAt == null || m.isAfter(bestAt)) {
            bestAt = m;
            best = e.path;
          }
        }
        if (best != null) return best;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _install(String path) async {
    if (Platform.isAndroid) {
      final r = await AppState.I.installApk(path);
      switch (r) {
        case 'started':
          MiuixToast.show('更新包已下载，正在安装…');
        case 'needPermission':
          // 已跳到系统授权页，回来后重试
          _retryPath = path;
          MiuixToast.show('请允许安装未知应用，返回后将自动安装');
        default:
          MiuixToast.show('安装失败：${r ?? '未知错误'}');
      }
      return;
    }
    if (Platform.isWindows) {
      await _runWindowsUpdate(path);
      return;
    }
  }

  /// 目录是否可写（Program Files 下需要管理员权限）
  static bool _canWrite(String dirPath) {
    try {
      final probe = File('$dirPath\\.fd_update_probe');
      probe.writeAsStringSync('probe');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Windows：写一个等待本进程退出、再解压覆盖并重启的脚本，然后退出应用
  static Future<void> _runWindowsUpdate(String zipPath) async {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final zip = zipPath.replaceAll('/', '\\');
    final target = dir.replaceAll('/', '\\');
    final exeWin = exe.replaceAll('/', '\\');
    final ts = DateTime.now().millisecondsSinceEpoch;
    final logPath =
        '${Directory.systemTemp.path}\\fd_update_$ts.log'.replaceAll('/', '\\');
    final script = File('${Directory.systemTemp.path}\\fd_update_$ts.ps1');
    final ps = '''
\$ErrorActionPreference = 'Stop'
\$log = '$logPath'
\$zip = '$zip'
\$target = '$target'
\$exe = '$exeWin'
function Write-Log(\$m) {
  try { ((Get-Date -Format 'HH:mm:ss') + ' ' + \$m) | Out-File -FilePath \$log -Append -Encoding utf8 } catch {}
}
try {
  Write-Log 'wait for app exit'
  try { Wait-Process -Id $pid -Timeout 120 -ErrorAction Stop } catch { Write-Log ('wait: ' + \$_.Exception.Message) }
  Start-Sleep -Milliseconds 1200
  Get-Process -Name 'gopeed' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 600
  Write-Log ('extract ' + \$zip + ' -> ' + \$target)
  Expand-Archive -LiteralPath \$zip -DestinationPath \$target -Force
  Write-Log 'extract ok'
  Start-Process -FilePath \$exe -WorkingDirectory \$target
  Write-Log 'restarted'
} catch {
  Write-Log ('FAILED: ' + \$_.Exception.Message)
}
''';
    final writable = _canWrite(dir);
    try {
      await script.writeAsString(ps, flush: true);
      if (writable) {
        await Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            script.path,
          ],
          mode: ProcessStartMode.detached,
        );
      } else {
        // 安装目录受保护（如 Program Files）：用 UAC 提权运行同一脚本
        final argList =
            "@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','${script.path.replaceAll('/', '\\')}')";
        await Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            "Start-Process -FilePath powershell.exe -ArgumentList $argList -Verb RunAs",
          ],
          mode: ProcessStartMode.detached,
        );
      }
    } catch (e) {
      AppLogger.I.e('update', '启动更新脚本失败: $e');
      MiuixToast.show('启动更新程序失败：$e');
      return;
    }
    AppLogger.I.i(
      'update',
      '更新包已就绪，退出并解压覆盖: $zip -> $target（可写=$writable, 日志=$logPath）',
    );
    MiuixToast.show(
      writable ? '更新包已下载，正在安装更新…' : '更新包已下载，请在弹出的 UAC 窗口点「是」',
    );
    await Future<void>.delayed(Duration(milliseconds: writable ? 600 : 4000));
    try {
      await GopeedEngine.stop().timeout(const Duration(seconds: 4));
    } catch (_) {}
    await WindowCloseHandler.exitApp();
  }
}
