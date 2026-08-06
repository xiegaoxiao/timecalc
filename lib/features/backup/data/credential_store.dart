import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// WebDAV 密码凭据存储抽象（NFR-3：凭据必须受保护）。
///
/// 密码不落业务数据库、不进备份文件（FR-9.5），存系统凭据存储
/// （Windows 上 flutter_secure_storage 走 DPAPI 加密）。测试 override
/// [webDavCredentialStoreProvider] 为内存假实现，不触碰平台通道。
abstract interface class WebDavCredentialStore {
  /// 保存指定 WebDAV 地址的密码。
  Future<void> save(String url, String password);

  /// 读取指定 WebDAV 地址的密码；未保存返回 null。
  Future<String?> read(String url);

  /// 删除指定 WebDAV 地址的密码。
  Future<void> delete(String url);
}

/// 基于 flutter_secure_storage 的默认实现（Windows DPAPI）。
class SecureCredentialStore implements WebDavCredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// 以地址为维度区分多套 WebDAV 凭据。
  static String _keyFor(String url) => 'webdav_password://$url';

  @override
  Future<void> save(String url, String password) {
    return _storage.write(key: _keyFor(url), value: password);
  }

  @override
  Future<String?> read(String url) {
    return _storage.read(key: _keyFor(url));
  }

  @override
  Future<void> delete(String url) {
    return _storage.delete(key: _keyFor(url));
  }
}

/// 凭据存储 Provider（测试 override 为内存假实现）。
final webDavCredentialStoreProvider = Provider<WebDavCredentialStore>((ref) {
  return SecureCredentialStore();
});
