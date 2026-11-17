import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A host as the network describes it.
class HostInfo {
  final String id, name, pin;
  List<String> addrs;
  bool online;
  bool self;
  String os;
  bool neverHub, prefer;
  int lastOk;

  HostInfo(this.id, this.name, this.pin,
      {this.addrs = const [], this.online = false, this.self = false, this.os = '', this.neverHub = false, this.prefer = false, this.lastOk = 0});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pin': pin, 'addrs': addrs, 'os': os, 'last_ok': lastOk};

  factory HostInfo.fromJson(Map<String, dynamic> j) => HostInfo(j['id'] as String, j['name'] as String? ?? '', j['pin'] as String? ?? '',
      addrs: ((j['addrs'] as List?) ?? const []).cast<String>(),
      online: j['online'] as bool? ?? false,
      self: j['self'] as bool? ?? false,
      os: j['os'] as String? ?? '',
      neverHub: j['never_hub'] as bool? ?? false,
      prefer: j['prefer'] as bool? ?? false,
      lastOk: (j['last_ok'] as num?)?.toInt() ?? 0);
}

/// Someone (host or client) waiting for approval.
class PendingReq {
  final String id, kind, name, pub, pin, code, via;
  final int at;
  PendingReq.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        kind = j['kind'] as String? ?? 'host',
        name = j['name'] as String? ?? '',
        pub = j['pub'] as String? ?? '',
        pin = j['pin'] as String? ?? '',
        code = j['code'] as String? ?? '',
        via = j['via'] as String? ?? '',
        at = (j['at'] as num?)?.toInt() ?? 0;
}

/// A member from the log.
class Member {
  final String id, kind, name, pub, pin, by;
  Member(this.id, this.kind, this.name, this.pub, this.pin, this.by);
}

/// What this device knows about its network: the member log (from a pinned host) and the last network view.
/// Kept in secure storage, so the app can show hosts and reach them after a restart, offline too.
class NetworkState {
  String net = '';
  String selfId = '';
  List<Map<String, dynamic>> events = [];
  Map<String, HostInfo> hosts = {}; // id -> last known addresses etc.
  String hub = '';
  int epoch = 0;
  String coordinator = '';
  List<PendingReq> pending = [];
  int updated = 0;

  static const _storage = FlutterSecureStorage();
  static const _key = 'goblin_network';

  bool get joined => net.isNotEmpty && selfId.isNotEmpty;

  static Future<NetworkState> load() async {
    final n = NetworkState();
    final raw = await _storage.read(key: _key);
    if (raw == null) return n;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      n.net = j['net'] as String? ?? '';
      n.selfId = j['self'] as String? ?? '';
      n.events = ((j['events'] as List?) ?? const []).cast<Map<String, dynamic>>();
      n.hub = j['hub'] as String? ?? '';
      n.epoch = (j['epoch'] as num?)?.toInt() ?? 0;
      n.updated = (j['updated'] as num?)?.toInt() ?? 0;
      for (final h in ((j['hosts'] as List?) ?? const [])) {
        final hi = HostInfo.fromJson(h as Map<String, dynamic>);
        n.hosts[hi.id] = hi;
      }
    } catch (_) {}
    return n;
  }

  Future<void> save() => _storage.write(
      key: _key,
      value: jsonEncode({
        'net': net,
        'self': selfId,
        'events': events,
        'hub': hub,
        'epoch': epoch,
        'updated': updated,
        'hosts': [for (final h in hosts.values) h.toJson()],
      }));

  static Future<void> wipe() => _storage.delete(key: _key);

  /// Current members: replay the log in order (an add counts if its signer is a member at that point; a removal
  /// is final) — the same rule as the hosts.
  List<Member> members() {
    final valid = <String, Member>{};
    final removed = <String>{};
    for (final e in events) {
      final id = e['id'] as String? ?? '';
      final by = e['by'] as String? ?? '';
      if (e['t'] == 'add') {
        if (removed.contains(id)) continue;
        final genesis = id == net && by == net;
        if (!genesis && !valid.containsKey(by)) continue;
        valid[id] = Member(id, e['kind'] as String? ?? '', e['name'] as String? ?? '', e['pub'] as String? ?? '',
            e['pin'] as String? ?? '', by);
      } else if (e['t'] == 'remove' && valid.containsKey(by)) {
        removed.add(id);
        valid.remove(id);
      }
    }
    return valid.values.toList();
  }

  bool get removedSelf => events.any((e) => e['t'] == 'remove' && e['id'] == selfId);

  /// Host members with their last known addresses (members without addresses yet are kept: learned later).
  List<HostInfo> hostList() {
    final out = <HostInfo>[];
    for (final m in members().where((m) => m.kind == 'host')) {
      final known = hosts[m.id];
      out.add(HostInfo(m.id, m.name, m.pin, addrs: known?.addrs ?? const [], online: known?.online ?? false, os: known?.os ?? '',
          neverHub: known?.neverHub ?? false, prefer: known?.prefer ?? false, lastOk: known?.lastOk ?? 0));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  List<Member> clients() => members().where((m) => m.kind == 'client').toList();

  /// Takes a /api/network answer.
  void applyView(Map<String, dynamic> v) {
    hub = v['hub'] as String? ?? hub;
    epoch = (v['epoch'] as num?)?.toInt() ?? epoch;
    coordinator = v['coordinator'] as String? ?? '';
    for (final h in ((v['hosts'] as List?) ?? const [])) {
      final hi = HostInfo.fromJson(h as Map<String, dynamic>);
      final old = hosts[hi.id];
      // keep addresses that worked before: a host on another network right now still has them next time
      if (old != null && hi.addrs.isEmpty) hi.addrs = old.addrs;
      hosts[hi.id] = hi;
    }
    pending = [for (final p in ((v['pending'] as List?) ?? const [])) PendingReq.fromJson(p as Map<String, dynamic>)];
    updated = DateTime.now().millisecondsSinceEpoch;
  }
}
