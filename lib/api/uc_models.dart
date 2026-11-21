import '../utils/types.dart';

/// UC 网盘用户信息（member 接口只返回会员类型等，没有昵称）。
class UcUserInfo {
  final String memberType;
  final String nickname;

  UcUserInfo({required this.memberType, required this.nickname});

  factory UcUserInfo.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    final map = data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
    return UcUserInfo(
      memberType: map['member_type']?.toString() ?? '',
      nickname: map['nickname']?.toString() ??
          map['nick_name']?.toString() ??
          map['user_name']?.toString() ??
          '',
    );
  }

  /// 展示用文案：昵称 > 会员类型中文 > 已登录
  String get label {
    if (nickname.isNotEmpty) return nickname;
    switch (memberType.toUpperCase()) {
      case 'NORMAL':
        return '普通用户';
      case 'VIP':
        return '会员';
      case 'SVIP':
        return '超级会员';
      default:
        return memberType.isEmpty ? '已登录' : memberType;
    }
  }
}

/// UC 网盘文件 / 文件夹（file/sort 返回的条目）。
class UcFile {
  final String fid;
  final String fileName;
  final bool isDir;
  final int size;
  final String pdirFid;
  final String formatType;
  final int updatedAt;
  final String objCategory;
  final String fileExt;

  UcFile({
    required this.fid,
    required this.fileName,
    required this.isDir,
    required this.size,
    required this.pdirFid,
    required this.formatType,
    required this.updatedAt,
    required this.objCategory,
    required this.fileExt,
  });

  factory UcFile.fromJson(Map<String, dynamic> json) {
    final name = json['file_name']?.toString() ?? '';
    final type = json['file_type']?.toString() ?? '';
    return UcFile(
      fid: json['fid']?.toString() ?? '',
      fileName: name,
      isDir: json['dir'] == true || type == 'folder',
      size: toInt(json['size']),
      pdirFid: json['pdir_fid']?.toString() ?? '',
      formatType: json['format_type']?.toString() ?? '',
      updatedAt: toInt(json['updated_at']),
      objCategory: json['obj_category']?.toString() ?? '',
      fileExt: _ext(name),
    );
  }

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 || i == name.length - 1 ? '' : name.substring(i + 1);
  }

  bool get isImage =>
      objCategory == 'image' ||
      ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic']
          .contains(fileExt.toLowerCase());
}

/// UC 下载直链条目（file/download 返回的 data 元素）。
class UcDownloadInfo {
  final String fid;
  final String url;
  final String fileName;
  final int size;

  UcDownloadInfo({
    required this.fid,
    required this.url,
    required this.fileName,
    required this.size,
  });

  factory UcDownloadInfo.fromJson(Map<String, dynamic> json) {
    return UcDownloadInfo(
      fid: json['fid']?.toString() ?? '',
      url: json['download_url']?.toString() ?? '',
      fileName: json['file_name']?.toString() ?? '',
      size: toInt(json['size']),
    );
  }
}
