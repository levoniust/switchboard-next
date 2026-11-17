import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/api.dart';
import 'package:switchboard/core/hub.dart';
import 'package:switchboard/core/identity.dart';
import 'package:switchboard/core/network.dart';

String link(Map<String, dynamic> j) => 'goblin://pair/${base64Url.encode(utf8.encode(jsonEncode(j))).replaceAll('=', '')}';

const _h = Server(name: 'x', hosts: ['1.2.3.4:8200'], pin: 'aaaaaaaaaaaaaaaa', id: 'h');

void main() {
  test('goblin pair link: one-time code, host id, network, addresses with ports', () {
    final s = Server.fromPairLink(
        link({'v': 1, 'net': 'n1', 'id': 'abc', 'n': 'laptop', 'h': ['100.1.2.3:8200'], 'c': 'FF', 'k': 'code1'}))!;
    expect(s.code, 'code1');
    expect(s.id, 'abc');
    expect(s.net, 'n1');
    expect(s.pin, 'ff');
    expect(s.toJson().containsKey('k'), isFalse); // the code is never stored
    expect(Server.fromPairLink(link({'v': 1, 'id': 'x', 'n': 'x', 'h': ['h:1'], 'c': 'ff'})), isNull); // no code
    expect(Server.fromPairLink('goblin://pair/garbage!!'), isNull);
  });

  test('signatures match the Go host byte for byte (fixed key)', () async {
    final me = await Identity.fromSeed(List<int>.filled(32, 1));
    expect(me.id, '34750f98bd59fcfc');
    expect(me.pubB64, 'iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w');
    expect(await me.sign('goblin-req1|target|GET|/api/sessions/%403/keys?a=1|1700000000000|nonce'),
        'FO5pQWlXQu6cRb0IQ0jZvT-q3lQW_toh1ahRG5-t7-O6vydMKX_J2n0i-PVY4-poFobbtUJsucpd_Jm4V6Z1AA');
    final text = ['goblin-ev1', 'net0', 'add', 'host', 'abcdef0123456789', 'PUB', 'Surface', 'pin', '1700000000000', me.id].join('|');
    expect(await me.sign(text),
        'kTQPfdUWCweMcFhUqXN1o9zSaIdd8ABnDfDm4apTAyX8NAPcV6U9_YV3_Ac-eEKPKPJkJhBGswZuw0jLmCABBg');
    final hdr = await me.signRequest('target', 'GET', '/api/x');
    expect(hdr.split('.').length, 4);
    expect(hdr.startsWith('${me.id}.'), isTrue);
  });

  test('member log replay: same rules as the hosts', () {
    final n = NetworkState()
      ..net = 'g'
      ..selfId = 'phone'
      ..events = [
        {'t': 'add', 'kind': 'host', 'id': 'g', 'name': 'desktop', 'pin': 'p1', 'by': 'g'},
        {'t': 'add', 'kind': 'client', 'id': 'phone', 'name': 'S23', 'by': 'g'},
        {'t': 'add', 'kind': 'host', 'id': 'sf', 'name': 'laptop', 'pin': 'p2', 'by': 'phone'},
        {'t': 'add', 'kind': 'client', 'id': 'evil', 'name': 'x', 'by': 'stranger'}, // signer not a member
        {'t': 'add', 'kind': 'client', 'id': 'old', 'name': 'old phone', 'by': 'g'},
        {'t': 'remove', 'id': 'old', 'by': 'phone'},
      ];
    expect(n.hostList().map((h) => h.name), ['desktop', 'laptop']);
    expect(n.clients().map((c) => c.name), ['S23']);
    expect(n.removedSelf, isFalse);
    n.events.add({'t': 'remove', 'id': 'phone', 'by': 'g'});
    expect(n.removedSelf, isTrue);
    // removing the phone does not drop the host it approved earlier
    expect(n.hostList().map((h) => h.name), ['desktop', 'laptop']);
  });

  test('network view keeps addresses that worked before', () {
    final n = NetworkState()..net = 'g';
    n.applyView({'hub': 'g', 'epoch': 3, 'hosts': [
      {'id': 'sf', 'name': 'laptop', 'pin': 'p', 'addrs': ['10.0.0.5:8200'], 'online': true},
    ]});
    n.applyView({'hub': 'sf', 'epoch': 4, 'hosts': [
      {'id': 'sf', 'name': 'laptop', 'pin': 'p', 'addrs': [], 'online': false},
    ], 'pending': [{'id': 'new', 'kind': 'host', 'name': 'Laptop', 'code': '0420', 'via': 'g'}]});
    expect(n.hosts['sf']!.addrs, ['10.0.0.5:8200']);
    expect(n.hub, 'sf');
    expect(n.epoch, 4);
    expect(n.pending.single.code, '0420');
  });

  test('fleet merges hosts; ids only unique per host', () {
    final f = Fleet();
    final ph = NodeLink(_h.copyWith(id: 'ph', name: 'alpha'));
    final sf = NodeLink(_h.copyWith(id: 'sf', name: 'laptop'));
    f.nodes.addAll([ph, sf]);
    ph.sessions = [Session.fromJson({'id': '@1', 'pane': '%1', 'name': 'claude'}, ph)];
    sf.sessions = [Session.fromJson({'id': '@1', 'pane': '%1', 'name': 'surface-ai'}, sf)];
    expect(f.sessions.map((s) => s.name), ['claude', 'surface-ai']);
    expect(f.sessions.map((s) => s.key).toSet().length, 2);
    expect(f.sessionById('@1', 'sf')!.name, 'surface-ai');
    expect(f.sessionByPane('%1', 'ph')!.name, 'claude');
    expect(f.node('nope'), isNull);
  });

  test('a beacon from a known host puts its new address first', () {
    final f = Fleet()..net = (NetworkState()..net = 'g');
    final sf = NodeLink(_h.copyWith(id: 'sf', name: 'laptop', hosts: ['192.168.1.30:8200']), null, f);
    f.nodes.add(sf);
    f.net.hosts['sf'] = HostInfo('sf', 'laptop', 'aa', addrs: ['192.168.1.30:8200']);
    f.pause(); // no real connections in the test
    f.heard('sf', '10.42.0.7:8200');
    expect(sf.server!.hosts, ['10.42.0.7:8200', '192.168.1.30:8200']);
    expect(f.net.hosts['sf']!.addrs.first, '10.42.0.7:8200');
    f.heard('nobody', '1.1.1.1:8200'); // unknown host: ignored
  });

  test('a removal answer is recognised as revoked', () {
    expect(ApiException(403, 'this device was removed from the network').revoked, isTrue);
    expect(ApiException(403, 'clients only').revoked, isFalse);
  });

  test('Windows paths shorten with backslashes', () {
    expect(Session.fromJson({'id': '1', 'cwd': r'C:\AI\projects\thing'}).shortCwd, r'…\projects\thing');
  });

  test('a host the app cannot reach goes through any host it can: hub first, then the fastest', () {
    NodeLink n(String id, {String? at, int ms = 0}) {
      final l = NodeLink(Server(name: id, hosts: const ['1.2.3.4:8200'], pin: 'aa', id: id));
      l.api!.activeHost = at;
      l.api!.latency = Duration(milliseconds: ms);
      return l;
    }

    final target = n('desktop');
    final surface = n('laptop', at: '100.1.1.1:8200', ms: 40);
    final pc = n('gaming-pc', at: '192.168.1.40:8200', ms: 8);
    final offline = n('vault');
    final all = [target, surface, pc, offline];
    expect(relayOrder(target, all, 'desktop').map((x) => x.id), ['gaming-pc', 'laptop']); // the hub is the target
    expect(relayOrder(target, all, 'laptop').map((x) => x.id), ['laptop', 'gaming-pc']); // hub first
    expect(relayOrder(target, [target, offline], 'vault'), isEmpty); // nobody reachable: no relay
  });

  test('upload path: only safe characters in the file name', () {
    expect(Api.uploadPath('IMG_2041.jpg'), '/api/upload?name=IMG_2041.jpg');
    expect(Api.uploadPath('/storage/emulated/0/DCIM/my photo (1).jpg'), '/api/upload?name=my-photo-1-.jpg');
    expect(Api.uploadPath(r'C:\x\pic.png'), '/api/upload?name=pic.png');
    expect(Api.uploadPath(''), '/api/upload?name=upload');
  });
}
