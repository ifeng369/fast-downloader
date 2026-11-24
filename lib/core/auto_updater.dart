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

  /// 防止一轮轮询里重复触发安装
  static bool _busy = false;

  /// Android：等用户授予「安装未知应用」后，回到前台重试的安装包路径
  static String? _retryPath;

  /// 读取持久化的待安装记录（应用重启后仍能续上）
  static Future<void> init() async {
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
    for (final task in tasks) {
      if (task.status != GopeedStatus.done) continue;
      if (!_matches(task, file)) continue;
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

  static bool _matches(GopeedTask task, String file) {
    if (task.name == file) return true;
    final p = task.filePath.replaceAll('\\', '/');
    if (p.isEmpty) return false;
    return p == file || p.endsWith('/$file');
  }

  static Future<String?> _resolvePath(GopeedTask task, String file) async {
    final direct = task.filePath;
    if (direct.isNotEmpty && await File(direct).exists()) return direct;
    final dir = await AppState.I.effectiveDownloadDir();
    final guess = '$dir${Platform.pathSeparator}$file';
    if (await File(guess).exists()) return guess;
    final byName = '$dir${Platform.pathSeparator}${task.name}';
    if (await File(byName).exists()) return byName;
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

  /// Windows：写一个等待本进程退出、再解压覆盖并重启的脚本，然后退出应用
  static Future<void> _runWindowsUpdate(String zipPath) async {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final zip = zipPath.replaceAll('/', '\\');
    final target = dir.replaceAll('/', '\\');
    final exeWin = exe.replaceAll('/', '\\');
    final script = File(
      '${Directory.systemTemp.path}\\fd_update_${DateTime.now().millisecondsSinceEpoch}.ps1',
    );
    final ps = '''
\$ErrorActionPreference = 'Stop'
try { Wait-Process -Id $pid -Timeout 180 -ErrorAction Stop } catch {}
Start-Sleep -Milliseconds 1500
Get-Process -Name 'gopeed' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Expand-Archive -LiteralPath '$zip' -DestinationPath '$target' -Force
Start-Process -FilePath '$exeWin' -WorkingDirectory '$target'
''';
    try {
      await script.writeAsString(ps, flush: true);
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
    } catch (e) {
      AppLogger.I.e('update', '启动更新脚本失败: $e');
      MiuixToast.show('启动更新程序失败：$e');
      return;
    }
    AppLogger.I.i('update', '更新包已就绪，退出并解压覆盖: $zip -> $target');
    MiuixToast.show('更新包已下载，正在安装更新…');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    try {
      await GopeedEngine.stop().timeout(const Duration(seconds: 4));
    } catch (_) {}
    await WindowCloseHandler.exitApp();
  }
}
