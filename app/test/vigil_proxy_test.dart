import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/screens/vigil_screen.dart';

/// The loopback proxy signs requests as this device, so other apps on the phone must not be able to use it:
/// only the start URL (with this run's secret) sets the cookie every other request needs.
void main() {
  test('vigil proxy needs the start secret', () async {
    final start = await LocalProxy.instance.ensure();
    final c = HttpClient();
    Future<HttpClientResponse> get(Uri u, {Cookie? cookie}) async {
      final req = await c.getUrl(u);
      req.followRedirects = false;
      if (cookie != null) req.cookies.add(cookie);
      return req.close();
    }

    final base = 'http://127.0.0.1:${start.port}';
    expect((await get(Uri.parse('$base/api/link/vigil/'))).statusCode, isNot(200));
    expect((await get(Uri.parse('$base/start?k=wrong'))).statusCode, 403);
    final ok = await get(start);
    expect(ok.statusCode, 302);
    expect(ok.headers.value(HttpHeaders.locationHeader), '/api/link/vigil/');
    final cookie = ok.cookies.single;
    expect(cookie.httpOnly, isTrue);
    // with the cookie but no computer offering Vigil: 503, not a pass-through
    expect((await get(Uri.parse('$base/api/link/vigil/'), cookie: cookie)).statusCode, 503);
    expect((await get(Uri.parse('$base/api/sessions'), cookie: cookie)).statusCode, isNot(200));
    c.close(force: true);
    await LocalProxy.instance.close();
  });
}
