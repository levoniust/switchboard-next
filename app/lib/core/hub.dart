import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../skins/chrome.dart';
import 'api.dart';
import 'cache.dart';
import 'identity.dart';
import 'network.dart';

class Session {
  final String id, name, pane, cwd, kind, status, last;
  final String? model;
  final Alert? pending;
  final int index;

  /// The machine this chat runs on (null only in tests).
  final NodeLink? node;

  Session.fromJson(Map<String, dynamic> j, [this.node])
      : id = j['id'] as String,
        index = (j['index'] as num?)?.toInt() ?? 0,
        name = j['name'] as String? ?? '',
        pane = j['pane'] as String? ?? '',
        cwd = j['cwd'] as String? ?? '',
        kind = j['kind'] as String? ?? 'shell',
        status = j['status'] as String? ?? 'idle',
        last = j['last'] as String? ?? '',
        model = j['model'] as String?,
        pending = j['pending'] == null ? null : Alert.fromJson(j['pending'] as Map<String, dynamic>, node);

  String get shortCwd {
    final sep = cwd.contains('\\') ? '\\' : '/';
    final parts = cwd.split(sep).where((p) => p.isNotEmpty).toList();
    return parts.length <= 2 ? cwd : '…$sep${parts.sublist(parts.length - 2).join(sep)}';
  }

  bool get isClaude => (node ?? hub0)?.launcher(kind).claude ?? kind != 'shell';

  /// Unique across machines (ids and panes are only unique within one machine).
  String get key => '${node?.id ?? ''}|$id';
}

/// One entry of the bridge's "new chat" menu (GET /api/info "launchers"). The bridge owner names them
/// (config.json "launchers"); older bridges send none, so the app falls back to [Launcher.defaults].
class Launcher {
  final String kind, label, name, icon;
  final bool claude;
  final int accent;
  const Launcher(this.kind, this.label, this.name, {this.claude = true, this.accent = 1, this.icon = 'chip'});

  Launcher.fromJson(Map<String, dynamic> j)
      : kind = j['kind'] as String,
        label = j['label'] as String? ?? j['kind'] as String,
        name = j['name'] as String? ?? j['kind'] as String,
        claude = j['claude'] as bool? ?? j['kind'] != 'shell',
        accent = (j['accent'] as num?)?.toInt() == 2 ? 2 : 1,
        icon = j['icon'] as String? ?? 'chip';

  static const defaults = [
    Launcher('claude', 'Claude', 'claude', icon: 'cloud'),
    Launcher('pi', 'Pi', 'pi', claude: false, accent: 2),
    Launcher('shell', 'Shell', 'shell', claude: false, icon: 'terminal'),
  ];
}

/// The last [NodeLink] created: lets a [Session] without a machine (tests) still find launchers.
NodeLink? hub0;

class AlertOption {
  final String key, label, detail;
  AlertOption(this.key, this.label, [this.detail = '']);
}

class Alert {
  final int id;
  final double ts;
  final String? pane, window, sessionName, kind;
  final String type, title, body, state;
  final String? answered;
  final List<AlertOption> options;
  final List<AlertOption> screenOptions;
  final NodeLink? node;

  Alert.fromJson(Map<String, dynamic> j, [this.node])
      : id = (j['id'] as num).toInt(),
        ts = (j['ts'] as num?)?.toDouble() ?? 0,
        pane = j['pane'] as String?,
        window = j['window'] as String?,
        sessionName = j['session_name'] as String?,
        kind = j['kind'] as String?,
        type = j['type'] as String? ?? 'info',
        title = j['title'] as String? ?? '',
        body = j['body'] as String? ?? '',
        state = j['state'] as String? ?? 'open',
        answered = j['answered'] as String?,
        options = ((j['options'] as List?) ?? [])
            .map((o) => AlertOption('${o['key']}', '${o['label']}', '${o['detail'] ?? ''}'))
            .toList(),
        screenOptions = ((j['screen_options'] as List?) ?? [])
            .map((o) => AlertOption('${o['key']}', '${o['label']}'))
            .toList();

  bool get needsAnswer => state == 'open' && (type == 'permission' || type == 'question');
  DateTime get time => DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
}

/// The Goblin client API this app speaks (goblin docs/PROTOCOL.md) and the features it needs for the basics.
const goblinApi = 1;
const coreFeatures = ['sessions', 'keys', 'screen', 'term', 'events', 'network'];

enum LinkState { offline, connecting, online }

/// A chat that could be restarted after the host rebooted (GET /api/resume).
class ResumeItem {
  final int index;
  final String kind, cwd, name;
  ResumeItem.fromJson(Map<String, dynamic> j)
      : index = (j['index'] as num).toInt(),
        kind = j['kind'] as String? ?? '',
        cwd = j['cwd'] as String? ?? '',
        name = j['name'] as String? ?? '';
}

/// One host: its chats and connection. Talks to the host directly when it can, through the hub's relay when it
/// can't. Keeps one events socket open while the app runs and reconnects with backoff.
class NodeLink extends ChangeNotifier {
  NodeLink(Server s, [this.identity, this.fleet]) {
    hub0 = this;
    server = s;
    api = Api(s, identity);
  }

  final Identity? identity;
  final Fleet? fleet;

  String get id => server?.id ?? '';
  String get name => server?.name ?? '';
  String os = 'linux';
  bool vigil = false;
  List<String> features = [];

  /// Goblin client API major version (0 = a node from before the contract was written down) and node version.
  int apiVersion = 0;
  String version = '';

  /// Web pages this node offers (goblin.yaml `links`), e.g. vigil.
  Map<String, String> links = {};

  /// Feature check (goblin docs/PROTOCOL.md): use a function only when the node lists it. Nodes from before API 1
  /// (Goblin 0.1) did not list the basics but have them.
  bool has(String feature) => features.contains(feature) || (apiVersion == 0 && _preContract.contains(feature));
  static const _preContract = {
    'sessions', 'keys', 'screen', 'term', 'events', 'network', 'approvals', 'relay', 'speedtest', 'launchers',
  };

  /// What a person should do about this computer's Goblin version, or null when all is well.
  String? get updateNote {
    if (features.isEmpty && apiVersion == 0) return null; // not connected yet
    if (apiVersion > goblinApi) {
      return 'Goblin $version is newer than this app: update Switchboard for its new features';
    }
    final missing = coreFeatures.where((f) => !has(f)).toList();
    if (missing.isNotEmpty) return 'Update Goblin on $name (missing: ${missing.join(', ')})';
    return null;
  }
  String sep = '/';

  Api? api;
  List<Launcher> launchers = Launcher.defaults;
  bool _launchersLoaded = false;

  Launcher launcher(String kind) => launchers.firstWhere((l) => l.kind == kind,
      orElse: () => Launcher(kind, kind, kind, claude: kind != 'shell'));
  Server? server;
  List<Session> sessions = [];
  List<Alert> alerts = [];
  List<ResumeItem> resumable = [];
  LinkState link = LinkState.offline;
  bool fromCache = false; // sessions shown are the offline copy
  String? error;
  final _alertCtrl = StreamController<Alert>.broadcast();
  Stream<Alert> get newAlerts => _alertCtrl.stream;

  WebSocket? _ws;
  Timer? _retry;
  int _backoff = 1;
  bool _paused = false;
  String? _focusPane;
  bool _windowActive = true;

  bool get windowActive => _windowActive;
  void setWindowActive(bool v) {
    if (v == _windowActive) return;
    _windowActive = v;
    setFocus(_focusPane);
  }

  /// The host this one is reached through when it can't be reached directly.
  NodeLink? relayNode;

  /// How the app reaches this host now: an address, `via <host>`, or null.
  String? get route => api?.activeHost ?? (api?.relayed == true ? 'via ${relayNode?.name ?? 'another host'}' : null);

  /// New addresses or certificate from the network: rebuild the client (keeps the chats on screen).
  void updateServer(Server s) {
    final old = server;
    server = s;
    if (old == null || old.pin != s.pin || old.hosts.join(',') != s.hosts.join(',')) {
      final via = api?.via;
      api = Api(s, identity)..via = via;
      if (link != LinkState.online) connect();
    }
  }

  Future<void> connect() async {
    if (api == null || _paused) return;
    _retry?.cancel();
    _ws?.close(); // never keep two event sockets
    _ws = null;
    link = LinkState.connecting;
    notifyListeners();
    try {
      api!.activeHost = null;
      api!.via = null;
      relayNode = null;
      if (await api!.probe() != null) {
        await refresh();
      } else {
        // not reachable directly: any host the app reaches passes it on (hub first, then the fastest); Goblin
        // finds the rest of the way across the network (2026-11-16: every host is a switch)
        Object? last;
        for (final r in fleet?.relaysFor(this) ?? const <NodeLink>[]) {
          api!.via = r.api;
          relayNode = r;
          try {
            await refresh();
            last = null;
            break;
          } catch (e) {
            last = e;
            api!.via = null;
            relayNode = null;
          }
        }
        if (api!.via == null) throw last ?? ApiException(0, 'not reachable');
      }
      final ws = await api!.socket('/api/events');
      if (_paused) {
        ws.close();
        return;
      }
      _ws = ws;
      link = LinkState.online;
      error = null;
      _backoff = 1;
      notifyListeners();
      setFocus(_focusPane);
      ws.listen(_onEvent, onDone: () {
        if (_ws == ws) _lost();
      }, onError: (_) {
        if (_ws == ws) _lost();
      }, cancelOnError: true);
    } catch (e) {
      error = '$e';
      await _loadCache();
      _lost();
    }
  }

  Future<void> _loadCache() async {
    if (sessions.isNotEmpty || id.isEmpty) return;
    final cached = await Cache.loadSessions(id);
    if (cached == null) return;
    sessions = cached.map((j) => Session.fromJson((j as Map).cast<String, dynamic>(), this)).toList();
    fromCache = true;
    notifyListeners();
  }

  void _lost() {
    _ws = null;
    if (link != LinkState.offline) {
      link = LinkState.offline;
      notifyListeners();
    }
    if (_paused) return;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), connect);
    _backoff = (_backoff * 2).clamp(1, 30);
  }

  /// App went to background: close the socket (no background connection, the design rules).
  void pause() {
    _paused = true;
    _retry?.cancel();
    _ws?.close();
    _ws = null;
    link = LinkState.offline;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    connect();
  }

  /// Reads a node's /api/info (separate for the contract tests).
  void applyInfo(Map<String, dynamic> info) {
    os = info['os'] as String? ?? 'linux';
    sep = os == 'windows' ? '\\' : '/';
    features = ((info['features'] as List?) ?? const []).cast<String>();
    apiVersion = (info['api'] as num?)?.toInt() ?? 0;
    version = info['version'] as String? ?? '';
    links = ((info['links'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));
    vigil = links.containsKey('vigil') || info['vigil'] == true;
    final ls = info['launchers'] as List?;
    if (ls != null && ls.isNotEmpty) {
      launchers = ls.map((j) => Launcher.fromJson(j as Map<String, dynamic>)).toList();
    }
  }

  Future<void> refresh() async {
    if (api == null) return;
    if (!_launchersLoaded) {
      final info = await api!.get('/api/info') as Map;
      applyInfo(info.cast<String, dynamic>());
      _launchersLoaded = true;
    }
    final s = await api!.get('/api/sessions') as List;
    sessions = s.map((j) => Session.fromJson(j as Map<String, dynamic>, this)).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    fromCache = false;
    Cache.saveSessions(id, s).ignore();
    if (has('alerts')) {
      try {
        final a = await api!.get('/api/alerts') as List;
        alerts = a.map((j) => Alert.fromJson((j as Map).cast<String, dynamic>(), this)).toList();
      } catch (_) {}
    }
    if (has('resume')) {
      try {
        final r = await api!.get('/api/resume') as List;
        resumable = r.map((j) => ResumeItem.fromJson(j as Map<String, dynamic>)).toList();
      } catch (_) {}
    }
    notifyListeners();
  }

  void _onEvent(dynamic data) {
    if (data is! String) return;
    final m = jsonDecode(data) as Map<String, dynamic>;
    switch (m['type']) {
      case 'alert': // Goblin 0.2.1+: a chat needs permission, asks something, or finished
        final j = m['alert'];
        if (j is Map) {
          final a = Alert.fromJson(j.cast<String, dynamic>(), this);
          alerts = [a, ...alerts.where((x) => x.id != a.id)];
          _alertCtrl.add(a);
          notifyListeners();
        }
        refresh().ignore();
        break;
      case 'status':
      case 'sessions':
        refresh().ignore();
        break;
      case 'network':
        fleet?.refreshNetwork().ignore();
        break;
      case 'speedtest':
        _speedTest(m).ignore();
        break;
      case 'info': // goblin.yaml changed on that computer: launchers or links may be different
        _launchersLoaded = false;
        refresh().ignore();
        break;
    }
  }

  /// The hub election asks this device to time each host (direct connections only) and report back.
  Future<void> _speedTest(Map<String, dynamic> m) async {
    final hosts = ((m['hosts'] as List?) ?? const []).map((h) => (h as Map)['id'] as String).toList();
    final results = <String, double>{};
    await Future.wait(hosts.map((hid) async {
      final n = fleet?.node(hid);
      if (n == null) return;
      final probe = Api(n.server!, identity);
      final ms = await probe.speedTest();
      if (ms != null) results[hid] = ms;
    }));
    _ws?.add(jsonEncode({'type': 'speedtest_result', 'test': m['test'], 'results': results}));
  }

  /// Tells the host which chat is on screen.
  void setFocus(String? pane) {
    _focusPane = pane;
    _ws?.add(jsonEncode({'type': 'focus', 'pane': focusValue(pane, _windowActive)}));
  }

  static String focusValue(String? pane, bool windowActive) => windowActive ? pane ?? '*' : '-';

  Session? sessionByPane(String? pane) {
    for (final s in sessions) {
      if (s.pane == pane) return s;
    }
    return null;
  }

  Session? sessionById(String id) {
    for (final s in sessions) {
      if (s.id == id || s.pane == id) return s;
    }
    return null;
  }

  int get openCount => alerts.where((a) => a.needsAnswer).length;

  Future<Alert> alert(int id) async => Alert.fromJson(await api!.get('/api/alerts/$id') as Map<String, dynamic>, this);

  Future<String> answer(int id, String key) async {
    final r = await api!.post('/api/alerts/$id/answer', {'key': key}) as Map;
    await refresh();
    return '${r['answered']}';
  }

  Future<void> sendKeys(Session s, {List<String> keys = const [], String? text}) =>
      api!.post('/api/sessions/${Uri.encodeComponent(s.id)}/keys', {'keys': keys, 'text': ?text});

  Future<String> newSession(String kind, String cwd, String name) async {
    final r = await api!.post('/api/sessions', {'kind': kind, 'cwd': cwd, 'name': name}) as Map;
    await refresh();
    return r['id'] as String;
  }

  Future<void> rename(Session s, String name) async {
    await api!.post('/api/sessions/${Uri.encodeComponent(s.id)}/rename', {'name': name});
    await refresh();
  }

  Future<void> kill(Session s) async {
    await api!.delete('/api/sessions/${Uri.encodeComponent(s.id)}');
    await refresh();
  }

  /// Restart chats from before a reboot (index null = all), or forget the list.
  Future<void> resumeChats({int? index, bool dismiss = false}) async {
    await api!.post('/api/resume', {'index': ?index, 'all': index == null && !dismiss, 'dismiss': dismiss});
    await refresh();
  }

  @override
  void dispose() {
    _paused = true;
    _retry?.cancel();
    _ws?.close();
    _alertCtrl.close();
    super.dispose();
  }
}

/// Every host of the network at once. The member log says which hosts exist; the closest host says which hub is
/// active and where the others are. Each [NodeLink] connects on its own, so one host being off never affects the
/// others.
class Fleet extends ChangeNotifier {
  final List<NodeLink> nodes = [];
  final _alertCtrl = StreamController<Alert>.broadcast();
  final _subs = <NodeLink, StreamSubscription<Alert>>{};
  Stream<Alert> get newAlerts => _alertCtrl.stream;
  bool _windowActive = true;
  Session? _focus;
  Identity? me;
  NetworkState net = NetworkState();
  Timer? _netTimer;
  RawDatagramSocket? _beacon;
  bool _netBusy = false;
  bool _paused = false;

  bool get paired => net.joined && me != null;

  /// Reads the saved network and key (before the first screen, so a paired app never opens on "Pair").
  Future<void> load() async {
    net = await NetworkState.load();
    if (!net.joined) return;
    me = await Identity.load();
    Api.onRevoked = () => wipe().ignore();
    if (net.removedSelf) return wipe();
    _syncNodes(connect: false); // start() connects
    _sortForPrompt();
  }

  Future<void> start() async {
    if (!paired) await load();
    if (!paired) {
      notifyListeners();
      return;
    }
    notifyListeners();
    await Future.wait(nodes.map((n) => n.connect()));
    await refreshNetwork();
    _startTimer();
  }

  /// Hosts announce themselves on the local network every 5 s (UDP 47820). Listening lets the app find a host at a
  /// new address with no internet and no Tailscale: a phone hotspot or travel router (the owner's travel rule).
  Future<void> _listenBeacons() async {
    if (_beacon != null) return;
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 47820, reuseAddress: true);
      sock.broadcastEnabled = true;
      _beacon = sock;
      sock.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = sock.receive();
        if (d == null) return;
        try {
          final m = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
          if (m['g'] != 'goblin1' || m['net'] != net.net) return;
          heard(m['id'] as String, '${d.address.address}:${m['port']}');
        } catch (_) {}
      });
    } catch (_) {} // port busy or not allowed: Tailscale and known addresses still work
  }

  /// A host answered at [addr]: remember it first in its list and connect if it was offline.
  void heard(String hostId, String addr) {
    final n = node(hostId);
    final h = net.hosts[hostId];
    if (n == null || n.server == null) return;
    if (n.server!.hosts.isNotEmpty && n.server!.hosts.first == addr) return;
    final addrs = [addr, ...n.server!.hosts.where((a) => a != addr)];
    if (h != null) h.addrs = addrs;
    n.updateServer(n.server!.copyWith(hosts: addrs));
    net.save().ignore();
    if (n.link != LinkState.online && !_paused) n.connect().ignore();
  }

  void _startTimer() {
    _listenBeacons().ignore();
    _netTimer?.cancel();
    _netTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_paused) refreshNetwork().ignore();
    });
  }

  /// Pairing finished: store the network and connect to every host in it.
  Future<void> joined(Identity id, Map<String, dynamic> pair, Server via) async {
    me = id;
    Api.onRevoked = () => wipe().ignore();
    net
      ..net = pair['net'] as String
      ..selfId = id.id
      ..events = ((pair['events'] as List?) ?? const []).cast<Map<String, dynamic>>();
    net.hosts[via.id!] = HostInfo(via.id!, via.name, via.pin, addrs: via.hosts);
    await net.save();
    _syncNodes();
    _sortForPrompt();
    notifyListeners();
    await Future.wait(nodes.map((n) => n.connect()));
    await refreshNetwork();
    _startTimer();
  }

  /// Make the node list match the hosts of the member log.
  void _syncNodes({bool connect = true}) {
    final hosts = net.hostList();
    final want = {for (final h in hosts) h.id};
    for (final n in List.of(nodes)) {
      if (!want.contains(n.id)) _detach(n);
    }
    for (final h in hosts) {
      final s = Server(name: h.name, hosts: h.addrs, pin: h.pin, id: h.id, net: net.net);
      final n = node(h.id);
      if (n == null) {
        final nn = NodeLink(s, me, this)..os = h.os.isEmpty ? 'linux' : h.os;
        _attach(nn);
        if (connect && !_paused && nn.link == LinkState.offline && s.hosts.isNotEmpty) nn.connect().ignore();
      } else {
        n.updateServer(s);
      }
    }
  }

  void _attach(NodeLink n) {
    nodes.add(n);
    n.addListener(notifyListeners);
    _subs[n] = n.newAlerts.listen(_alertCtrl.add);
  }

  void _detach(NodeLink n) {
    nodes.remove(n);
    n.removeListener(notifyListeners);
    _subs.remove(n)?.cancel();
    n.dispose();
  }

  void _sortForPrompt() => promptHost = nodes.isEmpty ? 'goblin' : nodes.first.name.toLowerCase();

  /// Hosts that can pass requests on to [who] when the app can't reach it directly: every other host the app
  /// reaches directly, the hub first, then by latency.
  List<NodeLink> relaysFor(NodeLink who) => relayOrder(who, nodes, net.hub);

  /// The closest host that answers directly (fastest probe).
  NodeLink? get closest {
    NodeLink? best;
    for (final n in nodes) {
      final a = n.api;
      if (a?.activeHost == null || a?.latency == null) continue;
      if (best == null || a!.latency! < best.api!.latency!) best = n;
    }
    return best;
  }

  /// Ask the closest host for the network (hub, hosts, addresses, waiting requests) and the member log.
  Future<void> refreshNetwork() async {
    if (_netBusy || !paired) return;
    _netBusy = true;
    try {
      var c = closest;
      if (c == null) {
        // nothing connected yet: probe everything once
        await Future.wait(nodes.map((n) => n.api!.probe()));
        c = closest;
      }
      if (c == null) return;
      final v = await c.api!.get('/api/network') as Map<String, dynamic>;
      final lg = await c.api!.get('/api/log') as Map<String, dynamic>;
      if (lg['net'] == net.net) net.events = ((lg['events'] as List?) ?? const []).cast<Map<String, dynamic>>();
      net.applyView(v);
      await net.save();
      if (net.removedSelf) {
        await wipe();
        return;
      }
      _syncNodes();
      // hosts that weren't reachable may be reachable through the hub now
      for (final n in nodes) {
        if (n.link == LinkState.offline && !_paused) n.connect().ignore();
      }
      notifyListeners();
    } catch (_) {
      // offline: keep the last known network
    } finally {
      _netBusy = false;
    }
  }

  /// Approve a waiting host or client: this device signs its add event.
  Future<void> approve(PendingReq p) async {
    final ev = await me!.event(net.net, t: 'add', kind: p.kind, target: p.id, pub: p.pub, name: p.name, pin: p.pin);
    final n = node(p.via) ?? closest;
    if (n == null) throw ApiException(0, 'no host reachable');
    await n.api!.post('/api/log', {'events': [ev]});
    await refreshNetwork();
  }

  Future<void> dismiss(PendingReq p) async {
    final n = node(p.via) ?? closest;
    await n?.api?.post('/api/pending/${p.id}/dismiss');
    await refreshNetwork();
  }

  /// Cut a host or client off for good (this device signs the removal).
  Future<void> removeMember(String id) async {
    final ev = await me!.event(net.net, t: 'remove', target: id);
    final n = closest;
    if (n == null) throw ApiException(0, 'no host reachable');
    await n.api!.post('/api/log', {'events': [ev]});
    await refreshNetwork();
  }

  /// Ask for a new hub test (the settings dropdown).
  Future<void> requestHubTest() async {
    final n = closest;
    if (n == null) throw ApiException(0, 'no host reachable');
    await n.api!.post('/api/network/test');
  }

  /// This device was removed (or "forget this device"): delete the key, the network and every offline copy.
  Future<void> wipe() async {
    _netTimer?.cancel();
    _beacon?.close();
    _beacon = null;
    for (final n in List.of(nodes)) {
      _detach(n);
    }
    await Cache.wipe();
    await NetworkState.wipe();
    await Identity.wipe();
    net = NetworkState();
    me = null;
    notifyListeners();
  }

  NodeLink? node(String? id) {
    if (nodes.isEmpty) return null;
    if (id == null || id.isEmpty) return nodes.first;
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  HostInfo? hostInfo(String id) => net.hosts[id];

  List<Session> get sessions => [for (final n in nodes) ...n.sessions];

  List<Alert> get alerts => [for (final n in nodes) ...n.alerts]..sort((a, b) => b.ts.compareTo(a.ts));

  int get openCount => nodes.fold(0, (sum, n) => sum + n.openCount);

  LinkState get link => nodes.any((n) => n.link == LinkState.online)
      ? LinkState.online
      : nodes.any((n) => n.link == LinkState.connecting)
          ? LinkState.connecting
          : LinkState.offline;

  /// The computer that shows the Vigil tab: online, has a vigil link and can pass it through (linkproxy). The hub
  /// is preferred, then the others in list order.
  NodeLink? get vigilNode {
    final ok = nodes.where((n) => n.link == LinkState.online && n.links.containsKey('vigil') && n.has('linkproxy')).toList();
    if (ok.isEmpty) return null;
    return ok.firstWhere((n) => n.id == net.hub, orElse: () => ok.first);
  }

  /// A computer that has a vigil link but runs a Goblin without linkproxy (shown as "update this computer").
  NodeLink? get vigilNeedsUpdate =>
      nodes.where((n) => n.links.containsKey('vigil') && !n.has('linkproxy')).firstOrNull;

  Future<void> connect() => Future.wait(nodes.map((n) => n.connect()));
  Future<void> refresh() => Future.wait(nodes.map((n) => n.refresh().catchError((_) {})));
  void pause() {
    _paused = true;
    for (final n in nodes) {
      n.pause();
    }
  }

  void resume() {
    _paused = false;
    for (final n in nodes) {
      n.resume();
    }
    refreshNetwork().ignore();
  }

  bool get windowActive => _windowActive;
  void setWindowActive(bool v) {
    _windowActive = v;
    for (final n in nodes) {
      n.setWindowActive(v);
    }
  }

  void setFocus(Session? s) {
    _focus = s;
    for (final n in nodes) {
      n.setFocus(s != null && s.node == n ? s.pane : null);
    }
  }

  Session? get focused => _focus;

  /// The chat a tapped notification points at: right after the app wakes up its list may be stale, so refresh
  /// that computer and try again for a few seconds.
  Future<Session?> findSession(String pane, String? nodeId) async {
    for (var i = 0; i < 12; i++) {
      final s = sessionByPane(pane, nodeId);
      if (s != null) return s;
      try {
        await (node(nodeId)?.refresh() ?? Future<void>.value());
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  Session? sessionByPane(String? pane, [String? nodeId]) {
    final n = node(nodeId);
    if (nodeId != null && n != null) return n.sessionByPane(pane);
    for (final x in nodes) {
      final s = x.sessionByPane(pane);
      if (s != null) return s;
    }
    return null;
  }

  Session? sessionById(String id, [String? nodeId]) {
    if (nodeId != null) return node(nodeId)?.sessionById(id);
    for (final x in nodes) {
      final s = x.sessionById(id);
      if (s != null) return s;
    }
    return null;
  }

  Session? sessionFor(Alert a) => a.node?.sessionByPane(a.pane) ?? sessionByPane(a.pane);

  Future<String> answer(Alert a, String key) => (a.node ?? nodes.first).answer(a.id, key);

  @override
  void dispose() {
    _netTimer?.cancel();
    for (final n in List.of(nodes)) {
      _detach(n);
    }
    _alertCtrl.close();
    super.dispose();
  }
}

/// Relay candidates for [who]: directly reachable hosts other than [who], the hub first, then the fastest.
List<NodeLink> relayOrder(NodeLink who, Iterable<NodeLink> all, String hub) {
  final c = all.where((n) => n != who && n.api?.activeHost != null).toList();
  int lat(NodeLink n) => n.api?.latency?.inMicroseconds ?? 1 << 40;
  c.sort((a, b) {
    if ((a.id == hub) != (b.id == hub)) return a.id == hub ? -1 : 1;
    return lat(a).compareTo(lat(b));
  });
  return c;
}
