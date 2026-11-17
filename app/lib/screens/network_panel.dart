import 'package:flutter/material.dart';

import '../core/hub.dart';
import '../core/network.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../skins/skins.dart';
import 'pair_screen.dart';

String _ago(int ms) {
  if (ms <= 0) return 'never';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// Settings → Network: active hub (dropdown + test), hosts, waiting approvals, devices, forget this device.
class NetworkPanel extends StatelessWidget {
  const NetworkPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    final net = hub.net;
    final hubName = hub.node(net.hub)?.name ?? (net.hub.isEmpty ? 'none yet' : net.hub);
    final hosts = net.hostList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (net.pending.isNotEmpty) const PendingCard(),
      ExpansionTile(
        leading: Icon(Icons.hub_outlined, color: skin.accent),
        title: Text('Active hub: $hubName', style: TextStyle(color: skin.fg)),
        subtitle: Text('picked by connection speed to this device · epoch ${net.epoch}', style: TextStyle(color: skin.dim, fontSize: 12)),
        children: [
          for (final h in hosts)
            ListTile(
              dense: true,
              leading: Icon(h.id == net.hub ? Icons.star : Icons.circle_outlined, size: 18, color: h.id == net.hub ? skin.accent : skin.dim),
              title: Text(h.name, style: TextStyle(color: skin.fg)),
              subtitle: Text([if (h.neverHub) 'never hub', if (h.prefer) 'preferred', h.online ? 'online' : 'offline'].join(' · '),
                  style: TextStyle(color: skin.dim, fontSize: 12)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.speed),
                label: const Text('Test again'),
                onPressed: () async {
                  try {
                    await hub.requestHubTest();
                    toast('Hub test started; the result shows here in a few seconds.');
                    Future.delayed(const Duration(seconds: 8), () => hub.refreshNetwork());
                  } catch (e) {
                    toast('Could not start a test: $e');
                  }
                },
              ),
            ),
          ),
        ],
      ),
      for (final h in hosts) _HostTile(h: h, skin: skin),
      ListTile(
        leading: const Icon(Icons.add_to_queue),
        title: Text('Add a computer', style: TextStyle(color: skin.fg)),
        subtitle: Text('Install goblin on it. On the same network it asks to join by itself; otherwise run '
            '`goblin join ADDRESS` there. Approve it here with the check code it shows.',
            style: TextStyle(color: skin.dim, fontSize: 12)),
      ),
      _sub(skin, 'Devices'),
      for (final c in net.clients())
        ListTile(
          dense: true,
          leading: Icon(c.id == net.selfId ? Icons.smartphone : Icons.devices_other, color: skin.dim),
          title: Text(c.name + (c.id == net.selfId ? ' (this device)' : ''), style: TextStyle(color: skin.fg)),
          subtitle: Text(c.id, style: TextStyle(color: skin.dim, fontFamily: 'JetBrainsMono', fontSize: 11)),
          trailing: c.id == net.selfId
              ? null
              : IconButton(
                  tooltip: 'Remove this device',
                  icon: Icon(Icons.person_remove_outlined, color: skin.danger),
                  onPressed: () => _remove(context, c.id, c.name, 'device')),
        ),
      ListTile(
        leading: Icon(Icons.logout, color: skin.danger),
        title: Text('Forget this device', style: TextStyle(color: skin.danger)),
        subtitle: Text('Removes it from the network and deletes its key and offline copies.', style: TextStyle(color: skin.dim, fontSize: 12)),
        onTap: () => _forgetSelf(context),
      ),
    ]);
  }

  Widget _sub(Skin skin, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
        child: Text(t, style: TextStyle(color: skin.dim, fontWeight: FontWeight.w600, fontSize: 12)),
      );
}

class _HostTile extends StatelessWidget {
  final HostInfo h;
  final Skin skin;
  const _HostTile({required this.h, required this.skin});

  @override
  Widget build(BuildContext context) {
    final n = hub.node(h.id);
    final on = n?.link == LinkState.online;
    final route = n?.route;
    return ListTile(
      leading: Icon(h.os == 'windows' ? Icons.laptop_windows : Icons.dns_outlined, color: on ? skin.accent : skin.dim),
      title: Text(h.name + (h.id == hub.net.hub ? '  · hub' : ''), style: TextStyle(color: skin.fg)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          on ? 'online · ${route ?? ''}' : 'offline · last seen ${_ago(h.lastOk)}',
          style: TextStyle(color: skin.dim, fontFamily: 'JetBrainsMono', fontSize: 12),
        ),
        if ((n?.version ?? '').isNotEmpty) Text('Goblin ${n!.version}', style: TextStyle(color: skin.dim, fontSize: 12)),
        if (n?.updateNote != null) Text(n!.updateNote!, style: TextStyle(color: skin.danger, fontSize: 12)),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: 'Reconnect', icon: const Icon(Icons.refresh), onPressed: n?.connect),
        IconButton(
          tooltip: 'Remove this computer from the network',
          icon: Icon(Icons.link_off, color: skin.danger),
          onPressed: () => _remove(context, h.id, h.name, 'computer'),
        ),
      ]),
    );
  }
}

/// Waiting hosts and devices with their check codes; shown in Settings and on the chat list.
class PendingCard extends StatelessWidget {
  const PendingCard({super.key});

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    return SkinPanel(
      skin: skin,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Waiting for your approval', style: TextStyle(color: skin.accent, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Approve only if the check code matches the one shown on that device.', style: TextStyle(color: skin.dim, fontSize: 12)),
        for (final p in hub.net.pending)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(children: [
              Icon(p.kind == 'host' ? Icons.computer : Icons.smartphone, color: skin.fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${p.name} (${p.kind == 'host' ? 'computer' : 'device'})\ncheck code ${p.code}',
                    style: TextStyle(color: skin.fg)),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await hub.dismiss(p);
                  } catch (e) {
                    toast('$e');
                  }
                },
                child: const Text('Dismiss'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    await hub.approve(p);
                    toast('${p.name} approved');
                  } catch (e) {
                    toast('Could not approve: $e');
                  }
                },
                child: const Text('Approve'),
              ),
            ]),
          ),
      ]),
    );
  }
}

Future<void> _remove(BuildContext context, String id, String name, String what) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Remove $name?'),
      content: Text('The $what is cut off from every computer of the network for good, including ones that are '
          'offline (they hear about it when they reconnect). It needs a new approval to come back.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await hub.removeMember(id);
    toast('$name removed');
  } catch (e) {
    toast('Could not remove: $e');
  }
}

Future<void> _forgetSelf(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Forget this device?'),
      content: const Text('This device leaves the network and deletes its key and offline copies. '
          'To come back, pair it again with `goblin pair`.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Forget')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await hub.removeMember(hub.net.selfId);
  } catch (_) {} // offline: the key is deleted here anyway; remove the device from another one later
  await hub.wipe();
  navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const PairScreen()), (_) => false);
}
