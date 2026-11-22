import '../../utils/types.dart';

enum GopeedStatus {
  ready,
  running,
  pause,
  wait,
  error,
  done;

  static GopeedStatus from(String? name) {
    switch (name) {
      case 'ready':
        return GopeedStatus.ready;
      case 'running':
        return GopeedStatus.running;
      case 'pause':
        return GopeedStatus.pause;
      case 'wait':
        return GopeedStatus.wait;
      case 'error':
        return GopeedStatus.error;
      case 'done':
        return GopeedStatus.done;
      default:
        return GopeedStatus.wait;
    }
  }

  String get label {
    switch (this) {
      case GopeedStatus.ready:
        return '等待中';
      case GopeedStatus.running:
        return '下载中';
      case GopeedStatus.pause:
        return '已暂停';
      case GopeedStatus.wait:
        return '排队中';
      case GopeedStatus.error:
        return '失败';
      case GopeedStatus.done:
        return '已完成';
    }
  }

  bool get isActive =>
      this == GopeedStatus.ready ||
      this == GopeedStatus.running ||
      this == GopeedStatus.wait;
}

class GopeedTask {
  final String id;
  final String name;
  final GopeedStatus status;
  final int size;
  final int downloaded;
  final int speed;
  final int createdAt;

  /// 下载文件的绝对路径（来自 Gopeed meta.opts.path + name；未知时为空）
  final String filePath;

  GopeedTask({
    required this.id,
    required this.name,
    required this.status,
    required this.size,
    required this.downloaded,
    required this.speed,
    required this.createdAt,
    this.filePath = '',
  });

  double get progress =>
      size <= 0 ? 0 : (downloaded / size).clamp(0.0, 1.0);

  factory GopeedTask.fromJson(Map<String, dynamic> json) {
    final progress = json['progress'] as Map<String, dynamic>? ?? const {};
    final meta = json['meta'] as Map<String, dynamic>? ?? const {};
    final res = meta['res'] as Map<String, dynamic>? ?? const {};
    final opts = meta['opts'] as Map<String, dynamic>? ?? const {};
    final dir = opts['path']?.toString() ?? '';
    final optName = opts['name']?.toString() ?? '';
    final filePath = dir.isEmpty
        ? ''
        : (optName.isEmpty ? dir : '$dir/$optName');
    return GopeedTask(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      status: GopeedStatus.from(json['status']?.toString()),
      size: toInt(res['size']),
      downloaded: toInt(progress['downloaded']),
      speed: toInt(progress['speed']),
      createdAt: toInt(json['createdAt']),
      filePath: filePath,
    );
  }
}
