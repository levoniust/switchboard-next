import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/links.dart';

List<String> t(String s) => findLinks(s).map((l) => '${l.url ? 'U' : 'F'}:${l.target}').toList();

void main() {
  test('web links, trailing punctuation left out', () {
    expect(t('See https://claude.ai/artifact/abc123.'), ['U:https://claude.ai/artifact/abc123']);
    expect(t('(http://192.168.1.20:30300/app/x.apk)'), ['U:http://192.168.1.20:30300/app/x.apk']);
    expect(t('https://en.wikipedia.org/wiki/Goblin_(disambiguation) ok'), ['U:https://en.wikipedia.org/wiki/Goblin_(disambiguation)']);
  });
  test('file paths on Linux and Windows', () {
    expect(t('Wrote /tmp/claude-1000/x/scratchpad/report.html, open it'), ['F:/tmp/claude-1000/x/scratchpad/report.html']);
    expect(t('saved ~/projects/goblin/docs/PROTOCOL.md'), ['F:~/projects/goblin/docs/PROTOCOL.md']);
    expect(t(r'see C:\AI\goblin-hooks\FINDINGS.md now'), [r'F:C:\AI\goblin-hooks\FINDINGS.md']);
    expect(t('C:/AI/goblin/goblin.exe hook claude'), ['F:C:/AI/goblin/goblin.exe']);
  });
  test('not links', () {
    expect(t('a/b and 1/2 and /usr/bin and and/or'), isEmpty); // no extension, or not absolute
    expect(t('https://x.org/a/b.html'), ['U:https://x.org/a/b.html']); // a URL's path is not also a file
  });
}
