import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/identity.dart';
import 'scan_screen.dart';
import '../core/platform.dart';
import '../main.dart';
import '../skins/chrome.dart';

/// The name this device shows in `goblin status` and on the other devices.
String deviceName() {
  final host = Platform.localHostname;
  final kind = Platform.isAndroid ? 'phone' : Platform.operatingSystem;
  return host.isEmpty || host == 'localhost' ? 'Switchboard $kind' : '$host ($kind)';
}

/// Join the network: accept a `goblin://pair/…` link from `goblin pair` (any host, needs its PIN), trade the
/// one-time code for membership. Every host of the network then shows up on its own.
class PairScreen extends StatefulWidget {
  final Server? initial;
  const PairScreen({super.key, this.initial});
  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _ctrl = TextEditingController();
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) WidgetsBinding.instance.addPostFrameCallback((_) => _pair(widget.initial!));
  }

  /// 2026-11-15: the QR code from `goblin pair` is scanned in the app (P1); pasting stays as the fallback.
  Future<void> _scan() async {
    final link = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (link == null || !mounted) return;
    _ctrl.text = link;
    final s = Server.fromPairLink(link);
    if (s == null) {
      setState(() => _status = 'That QR code holds a damaged pairing link.');
    } else {
      _pair(s);
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    if (d?.text != null) _ctrl.text = d!.text!.trim();
  }

  Future<void> _pair(Server s) async {
    if (hub.paired && s.net != hub.net.net) {
      setState(() => _status = 'This device already belongs to a Goblin network. To move it to another one, use '
          '"Forget this device" in Settings first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Testing ${s.hosts.join(' / ')} …';
    });
    final me = await Identity.load();
    final api = Api(s, me);
    final host = await api.probe();
    if (host == null) {
      setState(() {
        _busy = false;
        _status = 'Could not reach ${s.name}. Be on the same network (home Wi-Fi, hotspot) or turn Tailscale on. '
            '(It also fails if the certificate does not match the link.)';
      });
      return;
    }
    try {
      final r = await api.pair(deviceName());
      await hub.joined(me, r, s.copyWith(hosts: [host, ...s.hosts.where((h) => h != host)]));
      if (!mounted) return;
      setState(() => _status = 'Joined the network through ${s.name} ($host).');
      navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const HomeScreen()), (_) => false);
    } catch (e) {
      setState(() {
        _busy = false;
        _status = 'The host refused the code: $e\nCodes work once and expire after 10 minutes: run `goblin pair` again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    return Scaffold(
      body: SkinBackground(
        skin: skin,
        child: ListView(padding: EdgeInsets.zero, children: [
          SkinHeader(skin: skin, title: 'Pair', subtitle: isPhone ? 'connect this phone to a computer' : 'connect this device to a machine'),
          SkinPanel(
            skin: skin,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('On any computer of your Goblin network, run', style: TextStyle(color: skin.dim)),
              const SizedBox(height: 6),
              SelectableText('goblin pair', style: TextStyle(fontFamily: 'JetBrainsMono', color: skin.accent)),
              const SizedBox(height: 10),
              if (isPhone) ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(skin.head('Scan QR code')),
                ),
                const SizedBox(height: 12),
              ],
              Text('${isPhone ? 'Scan the QR code it shows, or paste' : 'Copy the link it prints and paste'} the link here. '
                  'All computers of the network then show up; new ones join by approval in Settings.',
                  style: TextStyle(color: skin.fg)),
              const SizedBox(height: 10),
              TextField(
                controller: _ctrl,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'goblin://pair/…',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(icon: const Icon(Icons.content_paste), onPressed: _paste),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        final s = Server.fromPairLink(_ctrl.text);
                        if (s == null) {
                          setState(() => _status = 'That is not a Goblin pairing link.');
                        } else {
                          _pair(s);
                        }
                      },
                icon: const Icon(Icons.link),
                label: Text(skin.head('Pair')),
              ),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Text(_status!, style: TextStyle(color: skin.fg)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
