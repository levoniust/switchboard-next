import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'identity.dart';

/// One host of the network: its member id, name, certificate pin and the addresses to try ("ip:port": home LAN,
/// Tailscale, hotspot...). [code] is only set on a pairing link (a one-time code, traded once, never saved).
class Server {
  final String name;
  final List<String> hosts;
  final String pin; // sha256 of the host certificate (DER), hex
  final String? id;
  final String? code;
  final String? net;

  const Server({required this.name, required this.hosts, required this.pin, this.id, this.code, this.net});

  Server copyWith({String? name, String? id, List<String>? hosts, String? pin}) =>
      Server(name: name ?? this.name, hosts: hosts ?? this.hosts, pin: pin ?? this.pin, id: id ?? this.id, net: net);

  Map<String, dynamic> toJson() => {'n': name, 'h': hosts, 'c': pin, 'id': ?id};

  factory Server.fromJson(Map<String, dynamic> j) => Server(
        name: j['n'] as String? ?? 'host',
        hosts: ((j['h'] as List?) ?? const []).cast<String>(),
        pin: (j['c'] as String? ?? '').toLowerCase(),
        id: j['id'] as String?,
        code: j['k'] as String?,
        net: j['net'] as String?,
      );

  /// Parses `goblin://pair/<base64url json>` (or just the payload) from `goblin pair`.
  static Server? fromPairLink(String link) {
    var payload = link.trim();
    final i = payload.indexOf('pair/');
    if (i >= 0) payload = payload.substring(i + 5);
    payload = payload.split('?').first;
    try {
      final s = Server.fromJson(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))) as Map<String, dynamic>);
      return s.code == null || s.id == null || s.pin.isEmpty || s.hosts.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  bool sameMachine(Server o) => id != null && id == o.id;
}

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  bool get revoked => status == 403 && message.contains('removed from the network');
  @override
  String toString() => message;
}

/// REST + WebSocket client for one host: certificate pinning, signed requests, direct or through the hub's relay.
class Api {
  final Server server;
  final Identity? identity;
  String? activeHost; // "ip:port" that answered last
  Duration? latency; // round trip of the last probe

  /// The hub this host is reached through when it can't be reached directly (null = direct).
  Api? via;

  late final HttpClient _http;

  /// Called when any host says this device was removed from the network.
  static void Function()? onRevoked;

  Api(this.server, [this.identity]) {
    _http = pinnedClient(server.pin);
  }

  static HttpClient pinnedClient(String pin) {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 20);
    // Hosts use self-signed certificates; we trust exactly the pinned one (its SHA-256), nothing else.
    c.badCertificateCallback = (X509Certificate cert, String host, int port) => sha256.convert(cert.der).toString() == pin;
    return c;
  }

  bool get relayed => activeHost == null && via?.activeHost != null;
  String get target => server.id ?? '';

  /// Tries every address at once; the fastest answer wins (home LAN beats Tailscale on its own).
  Future<String?> probe() async {
    final done = Completer<String?>();
    var left = server.hosts.length;
    if (left == 0) return null;
    for (final h in server.hosts) {
      () async {
        final t0 = DateTime.now();
        try {
          final req = await _http.getUrl(Uri.parse('https://$h/api/ping')).timeout(const Duration(seconds: 3));
          final res = await req.close().timeout(const Duration(seconds: 3));
          final body = await res.transform(utf8.decoder).join();
          final ok = res.statusCode == 200 && (server.id == null || (jsonDecode(body) as Map)['id'] == server.id);
          if (ok && !done.isCompleted) {
            latency = DateTime.now().difference(t0);
            done.complete(h);
          }
        } catch (_) {}
        if (--left == 0 && !done.isCompleted) done.complete(null);
      }();
    }
    return activeHost = await done.future;
  }

  /// Base URL and the path prefix for this host (direct, or `/relay/<id>` on the hub).
  (HttpClient, String, String) _route() {
    if (activeHost != null) return (_http, 'https://$activeHost', '');
    final v = via;
    if (v != null && v.activeHost != null) return (v._http, 'https://${v.activeHost}', '/relay/$target');
    throw ApiException(0, '${server.name} is not reachable');
  }

  Future<void> _ensure() async {
    if (activeHost != null || (via?.activeHost != null)) return;
    await probe();
  }

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    await _ensure();
    final (http, base, prefix) = _route();
    final inner = Uri.parse(path).replace(queryParameters: query);
    final innerStr = inner.query.isEmpty ? inner.path : '${inner.path}?${inner.query}';
    final uri = Uri.parse('$base$prefix$innerStr');
    try {
      final req = await http.openUrl(method, uri).timeout(const Duration(seconds: 6));
      if (identity != null) req.headers.set('X-Goblin-Auth', await identity!.signRequest(target, method, innerStr));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        final e = ApiException(res.statusCode, text.trim().isEmpty ? 'HTTP ${res.statusCode}' : text.trim());
        if (e.revoked) onRevoked?.call();
        throw e;
      }
      return text.isEmpty ? null : jsonDecode(text);
    } on SocketException {
      _drop();
      rethrow;
    } on TimeoutException {
      _drop();
      rethrow;
    } on HandshakeException {
      _drop();
      rethrow;
    }
  }

  void _drop() {
    if (activeHost != null) {
      activeHost = null; // network changed (home <-> away): probe again next time
    } else {
      via?.activeHost = null;
    }
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body ?? {});
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<WebSocket> socket(String path, {Map<String, String>? query}) async {
    await _ensure();
    final (http, base, prefix) = _route();
    final inner = Uri.parse(path).replace(queryParameters: query);
    final innerStr = inner.query.isEmpty ? inner.path : '${inner.path}?${inner.query}';
    final url = '${base.replaceFirst('https://', 'wss://')}$prefix$innerStr';
    try {
      final auth = identity == null ? '' : await identity!.signRequest(target, 'GET', innerStr);
      final ws = await WebSocket.connect(url, headers: {'X-Goblin-Auth': auth}, customClient: http)
          .timeout(const Duration(seconds: 8));
      ws.pingInterval = const Duration(seconds: 20);
      return ws;
    } on SocketException {
      _drop();
      rethrow;
    } on TimeoutException {
      _drop();
      rethrow;
    } on WebSocketException {
      _drop();
      rethrow;
    }
  }

  /// Times a small download from this host, directly (the hub test). null = not reachable directly.
  Future<double?> speedTest() async {
    if (await probe() == null) return null;
    final t0 = DateTime.now();
    try {
      final (http, base, _) = _route();
      const p = '/api/speedtest?bytes=65536';
      final req = await http.getUrl(Uri.parse('$base$p')).timeout(const Duration(seconds: 5));
      if (identity != null) req.headers.set('X-Goblin-Auth', await identity!.signRequest(target, 'GET', p));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return DateTime.now().difference(t0).inMicroseconds / 1000;
    } catch (_) {
      return null;
    }
  }

  /// Trades a pairing link's one-time code for membership. Returns {id, net, host, events}.
  Future<Map<String, dynamic>> pair(String deviceName) async {
    final r = await post('/api/pair', {'code': server.code, 'name': deviceName, 'pub': identity!.pubB64}) as Map;
    return r.cast<String, dynamic>();
  }

  /// Sends a file to this host (Goblin feature `upload`); returns where it was saved there.
  Future<String> upload(String filename, Uint8List bytes) async {
    final (code, _, body) = await raw('POST', uploadPath(filename),
        body: bytes, headers: {'content-type': 'application/octet-stream'});
    final text = utf8.decode(body, allowMalformed: true).trim();
    if (code != 200) throw ApiException(code, text.isEmpty ? 'HTTP $code' : text);
    return (jsonDecode(text) as Map)['path'] as String;
  }

  /// The upload URL for a file name: only safe characters, so the signed path is the same on both ends.
  static String uploadPath(String filename) {
    var n = filename.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    if (n.isEmpty) n = 'upload';
    return '/api/upload?name=$n';
  }

  /// Any signed request with raw bytes, direct or through the hub (the Vigil tab's proxy). [pathAndQuery] is sent
  /// and signed exactly as given. Redirects are returned, not followed.
  Future<(int, HttpHeaders, List<int>)> raw(String method, String pathAndQuery,
      {List<int>? body, Map<String, String>? headers}) async {
    await _ensure();
    final (http, base, prefix) = _route();
    try {
      final req = await http.openUrl(method, Uri.parse('$base$prefix$pathAndQuery')).timeout(const Duration(seconds: 8));
      req.followRedirects = false;
      if (identity != null) req.headers.set('X-Goblin-Auth', await identity!.signRequest(target, method, pathAndQuery));
      headers?.forEach(req.headers.set);
      if (body != null && body.isNotEmpty) req.add(body);
      final res = await req.close().timeout(const Duration(seconds: 30));
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 60));
      return (res.statusCode, res.headers, bytes);
    } on SocketException {
      _drop();
      rethrow;
    } on TimeoutException {
      _drop();
      rethrow;
    } on HandshakeException {
      _drop();
      rethrow;
    }
  }

  String vigilUrl() => '';
}
