import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// The offline copy (the design rules 6): the last 5,000 lines of every chat and each host's chat list, encrypted
/// (AES-GCM, key in secure storage), so the app can show the last sync with no connection. Wiped on revoke.
class Cache {
  static const maxLines = 5000;
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'goblin_cache_key';
  static final _aes = AesGcm.with256bits();
  static SecretKey? _key;
  static Directory? _dir;

  /// Tests (and platforms without a documents folder) can point the cache somewhere else.
  static Directory? overrideDir;

  static Future<SecretKey> _secret() async {
    if (_key != null) return _key!;
    var raw = await _storage.read(key: _keyName);
    if (raw == null) {
      final b = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      raw = base64.encode(b);
      await _storage.write(key: _keyName, value: raw);
    }
    return _key = SecretKey(base64.decode(raw));
  }

  static Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final base = overrideDir ?? await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}goblin-cache');
    await d.create(recursive: true);
    return _dir = d;
  }

  static String _name(String kind, String a, [String b = '']) => '$kind-${hash.sha256.convert(utf8.encode('$a|$b')).toString().substring(0, 24)}.bin';

  static Future<void> _write(String name, Object value) async {
    final box = await _aes.encrypt(utf8.encode(jsonEncode(value)), secretKey: await _secret());
    final f = File('${(await _folder()).path}${Platform.pathSeparator}$name');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(box.concatenation(), flush: true);
    await tmp.rename(f.path);
  }

  static Future<dynamic> _read(String name) async {
    try {
      final f = File('${(await _folder()).path}${Platform.pathSeparator}$name');
      if (!await f.exists()) return null;
      final box = SecretBox.fromConcatenation(await f.readAsBytes(), nonceLength: 12, macLength: 16);
      return jsonDecode(utf8.decode(await _aes.decrypt(box, secretKey: await _secret())));
    } catch (_) {
      return null; // damaged or from an old key: no offline copy
    }
  }

  static Future<void> saveLines(String host, String session, List<String> lines) =>
      _write(_name('chat', host, session), lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines);

  static Future<List<String>?> loadLines(String host, String session) async =>
      ((await _read(_name('chat', host, session))) as List?)?.cast<String>();

  static Future<void> saveSessions(String host, List<dynamic> sessions) => _write(_name('sessions', host), sessions);

  static Future<List<dynamic>?> loadSessions(String host) async => (await _read(_name('sessions', host))) as List?;

  /// Revoked or forgotten: delete every copy and the key.
  static Future<void> wipe() async {
    try {
      final d = await _folder();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
    _dir = null;
    _key = null;
    await _storage.delete(key: _keyName);
  }
}
