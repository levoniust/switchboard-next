import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/hub.dart';
import 'package:switchboard/skins/skins.dart';

void main() {
  test('session + alert parsing', () {
    final s = Session.fromJson({
      'id': '@1', 'index': 1, 'name': 'qwen', 'pane': '%3', 'cwd': '/home/me/projects/goblin/app', 'kind': 'claude-local',
      'status': 'question', 'pending': {'id': 5, 'type': 'question', 'title': 'Color', 'body': 'Which?', 'state': 'open',
        'options': [{'key': '1', 'label': 'Red'}, {'key': '2', 'label': 'Green'}]},
    });
    expect(s.shortCwd, '…/goblin/app');
    expect(s.pending!.needsAnswer, isTrue);
    expect(s.pending!.options.map((o) => o.label), ['Red', 'Green']);
  });

  test('every skin builds a theme; Miko skins are private', () {
    for (final s in skins) {
      expect(s.theme, isNotNull);
    }
    expect(skins.where((s) => s.isPrivate).length, 6);
    expect(skinById('nope').id, 'cli');
  });
}
