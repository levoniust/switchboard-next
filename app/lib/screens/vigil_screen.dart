import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/platform.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../skins/skins.dart';

/// Vigil (the homelab watchtower) through a Goblin computer, so it works away from home too.
/// The computer that has `links: vigil:` in its goblin.yaml fetches the pages (feature linkproxy), directly or through
/// the hub. Android's WebView won't trust Goblin's self-signed certificate, so the app runs a tiny proxy on 127.0.0.1
/// that forwards over the pinned, signed connection. On a computer the same proxy opens in the default browser.
class VigilScreen extends StatefulWidget {
  final bool standalone;
  const VigilScreen({super.key, this.standalone = false});
  @override
  State<VigilScreen> createState() => _VigilScreenState();
}

class _VigilScreenState extends State<VigilScreen> {
  WebViewController? _web;
  Uri? _start; // the proxy is ready
  String? _error;

  @override
  void initState() {
    super.initState();
    hub.addListener(_onFleet);
    _begin();
  }

  @override
  void dispose() {
    hub.removeListener(_onFleet);
    super.dispose();
  }

  /// A computer with Vigil came online after the tab opened: load it now.
  void _onFleet() {
    if (_start == null && _error != null && hub.vigilNode != null) {
      _error = null;
      _begin();
    }
  }

  Future<void> _begin() async {
    if (hub.vigilNode == null) {
      final old = hub.vigilNeedsUpdate;
      setState(() => _error = old != null
          ? 'Vigil is set up on ${old.name}, but its Goblin is too old to show it here. Update Goblin on ${old.name}.'
          : 'No computer offers Vigil yet. Add it to goblin.yaml on one of them:\n\nlinks:\n  vigil: http://ADDRESS:30300');
      return;
    }
    try {
      final start = await LocalProxy.instance.ensure();
      if (isDesktop) {
        setState(() => _start = start);
        return;
      }
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(settings.skin.bg)
        ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: _onNavigation))
        ..loadRequest(start);
      setState(() {
        _start = start;
        _web = c;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _openInBrowser() async {
    if (_start == null) return;
    final ok = await launchUrl(_start!, mode: LaunchMode.externalApplication);
    if (!ok) toast('Could not open the browser');
  }

  Widget _desktopBody(Skin skin) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error ?? (_start == null ? 'Starting…' : 'Vigil opens in your browser, through this app.'),
              style: TextStyle(color: skin.dim), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _start == null ? null : _openInBrowser,
            icon: const Icon(Icons.open_in_browser),
            label: Text(skin.head('Open Vigil')),
          ),
          const SizedBox(height: 8),
          Text('The page works while Switchboard is running.', style: TextStyle(color: skin.dim, fontSize: 12)),
        ]),
      );

  /// Vigil itself stays in the WebView; its links to lab services (plain http on the home network, reachable away
  /// from home over Tailscale's subnet route) open in the phone's browser: the WebView refuses cleartext pages.
  NavigationDecision _onNavigation(NavigationRequest req) {
    final uri = Uri.tryParse(req.url);
    if (uri == null || uri.host == '127.0.0.1' || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return NavigationDecision.navigate;
    }
    launchUrl(uri, mode: LaunchMode.externalApplication).then((ok) {
      if (!ok) toast('Could not open ${uri.host}');
    });
    return NavigationDecision.prevent;
  }

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    final via = hub.vigilNode?.name;
    final body = Column(children: [
      SkinHeader(skin: skin, title: 'Vigil', subtitle: via == null ? 'homelab watchtower' : 'homelab watchtower · via $via', actions: [
        if (isPhone)
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                if (_web != null) {
                  _web!.reload();
                } else {
                  setState(() => _error = null);
                  _begin();
                }
              }),
      ]),
      Expanded(
        child: isDesktop
            ? _desktopBody(skin)
            : _web != null
                ? WebViewWidget(controller: _web!)
                : Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error ?? 'Starting…', style: TextStyle(color: skin.dim), textAlign: TextAlign.center))),
      ),
    ]);
    if (!widget.standalone) return body;
    return Scaffold(body: SkinBackground(skin: skin, child: body));
  }
}

/// Loopback HTTP proxy → the Vigil computer's /api/link/vigil/ (pinned TLS, signed, direct or via the hub).
/// Other apps on this device can reach 127.0.0.1 too, so every request needs the cookie that only the start URL
/// (with this run's secret) sets.
class LocalProxy {
  static final instance = LocalProxy._();
  LocalProxy._();
  HttpServer? _server;
  final String _secret = List.generate(24, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  static const _prefix = '/api/link/vigil/';
  static const _cookie = 'sbv';

  /// Starts the proxy and returns the address to open first.
  Future<Uri> ensure() async {
    _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen(_handle);
    return Uri.parse('http://127.0.0.1:${_server!.port}/start?k=$_secret');
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  bool _cookieOk(HttpRequest req) => req.cookies.any((c) => c.name == _cookie && c.value == _secret);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path == '/start') {
      if (req.uri.queryParameters['k'] != _secret) {
        res.statusCode = 403;
      } else {
        res.cookies.add(Cookie(_cookie, _secret)
          ..httpOnly = true
          ..path = '/');
        res.statusCode = 302;
        res.headers.set(HttpHeaders.locationHeader, _prefix);
      }
      await res.close();
      return;
    }
    final node = hub.vigilNode;
    final path = req.uri.path.toLowerCase();
    if (!_cookieOk(req) || node == null || node.api == null || !path.startsWith(_prefix) || path.contains('..') ||
        path.contains('%2e')) {
      res.statusCode = node == null ? 503 : 404;
      await res.close();
      return;
    }
    try {
      final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final hdr = <String, String>{};
      for (final h in const ['content-type', 'accept', 'accept-language']) {
        final v = req.headers.value(h);
        if (v != null) hdr[h] = v;
      }
      final (status, headers, bytes) = await node.api!.raw(req.method, req.uri.toString(), body: body, headers: hdr);
      res.statusCode = status;
      for (final h in const ['content-type', 'cache-control', 'location']) {
        final v = headers.value(h);
        if (v != null) res.headers.set(h, v);
      }
      res.add(bytes);
    } catch (e) {
      res.statusCode = 502;
      res.write('Vigil is not reachable through ${node.name}: $e');
    }
    await res.close();
  }
}
