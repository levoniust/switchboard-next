/// Links in chat text (2026-11-16: tap a link or a file an agent mentions to open it).
class Link {
  final int start, end;
  final String target;
  final bool url; // false = a file path on the chat's computer
  const Link(this.start, this.end, this.target, this.url);
}

final _url = RegExp(r'''https?://[^\s<>"'`]+''');
final _unixPath = RegExp(r'''(?<![\w.~/:-])~?/(?:[\w.@+-]+/)+[\w.@+-]+\.[A-Za-z0-9]{1,8}(?![\w/])''');
final _winPath = RegExp(r'''(?<![\w])[A-Za-z]:[\\/](?:[^\\/\s:*?"<>|`']+[\\/])*[^\\/\s:*?"<>|`']+\.[A-Za-z0-9]{1,8}(?![\w\\/])''');
const _trail = '.,;:!?)]}\'"';

/// Every web link and file path in [text], in order, never overlapping.
List<Link> findLinks(String text) {
  final out = <Link>[];
  for (final m in _url.allMatches(text)) {
    var e = m.end;
    while (e > m.start && _trail.contains(text[e - 1])) {
      // keep a closing bracket that belongs to the link, as in wiki URLs: (x)
      final c = text[e - 1];
      if (c == ')' && text.substring(m.start, e).contains('(')) break;
      e--;
    }
    out.add(Link(m.start, e, text.substring(m.start, e), true));
  }
  bool free(int s, int e) => out.every((l) => e <= l.start || s >= l.end);
  for (final re in [_winPath, _unixPath]) {
    for (final m in re.allMatches(text)) {
      if (free(m.start, m.end)) out.add(Link(m.start, m.end, m.group(0)!, false));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}
