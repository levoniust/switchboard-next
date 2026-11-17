import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/api.dart';
import 'package:switchboard/core/hub.dart';

/// Goblin client API contract (goblin docs/PROTOCOL.md) against /api/info answers recorded from real nodes
/// (`goblin-check -dump-info`, then anonymized): one per Goblin version the app must keep working with.
Map<String, dynamic> _info(String f) =>
    jsonDecode(File('test/fixtures/$f').readAsStringSync()) as Map<String, dynamic>;

NodeLink _node(String f) =>
    NodeLink(const Server(name: 'n', hosts: ['127.0.0.1:8200'], pin: 'x', id: 'n'))..applyInfo(_info(f));

void main() {
  test('Goblin 0.2 with linkproxy: API 1, all basics, Vigil link usable', () {
    final n = _node('info-goblin-0.2-linkproxy.json');
    expect(n.apiVersion, goblinApi);
    expect(n.version, '0.2.0');
    for (final f in [...coreFeatures, 'resume', 'fs', 'linkproxy']) {
      expect(n.has(f), isTrue, reason: f);
    }
    expect(n.links['vigil'], startsWith('http'));
    expect(n.vigil, isTrue);
    expect(n.updateNote, isNull);
    expect(n.launchers.map((l) => l.kind), contains('shell'));
  });

  test('Goblin 0.2 without linkproxy: works, but cannot show a link', () {
    final n = _node('info-goblin-0.2.json');
    expect(n.updateNote, isNull);
    expect(n.has('linkproxy'), isFalse);
    expect(n.launchers.length, greaterThan(1));
  });

  test('Goblin 0.1 (before the contract): basics assumed, not flagged', () {
    final n = _node('info-goblin-0.1.json');
    expect(n.apiVersion, 0);
    for (final f in coreFeatures) {
      expect(n.has(f), isTrue, reason: f);
    }
    expect(n.has('linkproxy'), isFalse);
    expect(n.updateNote, isNull);
  });

  test('a newer API or missing basics are explained', () {
    final newer = _node('info-goblin-0.2.json')..applyInfo({..._info('info-goblin-0.2.json'), 'api': goblinApi + 1, 'version': '9.0.0'});
    expect(newer.updateNote, contains('update Switchboard'));
    final broken = _node('info-goblin-0.2.json')..applyInfo({..._info('info-goblin-0.2.json'), 'features': ['sessions']});
    expect(broken.updateNote, contains('Update Goblin'));
  });
}
