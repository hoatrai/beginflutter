import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageHelper {
  static const _storage = FlutterSecureStorage(
    // xóa options cũ đã lỗi thời
    // aOptions: AndroidOptions(encryptedSharedPreferences: false),
  );

  static Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
    debugPrint(">>> [DEBUG] StorageHelper: wrote $key = $value");
  }

  static Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    debugPrint(">>> [DEBUG] StorageHelper: read $key = $value");
    return value;
  }

  static Future<void> delete(String key) async {
    await _storage.delete(key: key);
    debugPrint(">>> [DEBUG] StorageHelper: deleted $key");
  }
  static Future<void> clear() async {
    await _storage.deleteAll();
    debugPrint(">>> [DEBUG] StorageHelper: cleared all keys");
  }

}
