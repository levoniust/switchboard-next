import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// This device's Ed25519 key. Every request is signed with it (no tokens), and approvals are member-log events
/// signed with it. Member id = first 16 hex of sha256(public key), the same as on the hosts.
class Identity {
  final SimpleKeyPair _pair;
  final List<int> pub;
  final String id;

  Identity._(this._pair, this.pub) : id = memberId(pub);

  static final _ed = Ed25519();
  static const _storage = FlutterSecureStorage();
  static const _key = 'goblin_key';

  static String memberId(List<int> pub) => hash.sha256.convert(pub).toString().substring(0, 16);

  static String b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
  static List<int> unb64(String s) => base64Url.decode(base64Url.normalize(s));

  String get pubB64 => b64(pub);

  /// The stored key, or a new one.
  static Future<Identity> load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) return fromSeed(unb64(raw));
    final seed = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await _storage.write(key: _key, value: b64(seed));
    return fromSeed(seed);
  }

  static Future<Identity> fromSeed(List<int> seed) async {
    final kp = await _ed.newKeyPairFromSeed(seed);
    final pk = await kp.extractPublicKey();
    return Identity._(kp, pk.bytes);
  }

  /// Forget the key (this device was removed from the network, or "start over").
  static Future<void> wipe() => _storage.delete(key: _key);

  Future<String> sign(String text) async => b64((await _ed.sign(utf8.encode(text), keyPair: _pair)).bytes);

  /// Value of the X-Goblin-Auth header for a request to host [target]. [uri] = path + query exactly as sent.
  Future<String> signRequest(String target, String method, String uri) async {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = b64(Uint8List.fromList(List<int>.generate(9, (_) => Random.secure().nextInt(256))));
    final sig = await sign(['goblin-req1', target, method, uri, ts, nonce].join('|'));
    return [id, ts, nonce, sig].join('.');
  }

  /// A signed member-log event (same text form as the Go host: never JSON).
  Future<Map<String, dynamic>> event(String net,
      {required String t, String kind = '', required String target, String pub = '', String name = '', String pin = ''}) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final text = ['goblin-ev1', net, t, kind, target, pub, name, pin, '$ts', id].join('|');
    return {
      't': t,
      if (kind.isNotEmpty) 'kind': kind,
      'id': target,
      if (pub.isNotEmpty) 'pub': pub,
      if (name.isNotEmpty) 'name': name,
      if (pin.isNotEmpty) 'pin': pin,
      'ts': ts,
      'by': id,
      'sig': await sign(text),
    };
  }
}
