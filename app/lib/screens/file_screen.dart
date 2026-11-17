import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/hub.dart';

/// A file a chat mentioned, fetched read-only from that chat's computer (Goblin feature `file`): web pages in a
/// web view, pictures as pictures, text as text.
class FileScreen extends StatefulWidget {
  final NodeLink node;
  final String path;
  const FileScreen({super.key, required this.node, required this.path});

  @override
  State<FileScreen> createState() => _FileScreenState();
}

class _FileScreenState extends State<FileScreen> {
  String? _error, _type, _text;
  List<int>? _bytes;
  WebViewController? _web;

  String get _name => widget.path.split(RegExp(r'[\\/]')).last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (!widget.node.has('file')) throw 'Update Goblin on ${widget.node.name} to open files from chats';
      final (code, headers, body) =
          await widget.node.api!.raw('GET', '/api/file?path=${Uri.encodeQueryComponent(widget.path)}');
      if (code != 200) throw utf8.decode(body, allowMalformed: true).trim();
      final type = (headers.contentType?.mimeType ?? 'application/octet-stream').toLowerCase();
      if (type == 'text/html') {
        // a local copy in the app's cache (sandboxed web view, JavaScript on for pages that need it)
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/goblin-file-${widget.path.hashCode & 0xffffff}-$_name');
        await f.writeAsBytes(body);
        _web = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..loadFile(f.path);
      } else if (!type.startsWith('image/')) {
        final t = utf8.decode(body, allowMalformed: true);
        if (type.startsWith('text/') || type.contains('json') || type.contains('xml') || !t.contains('�')) _text = t;
      }
      setState(() {
        _type = type;
        _bytes = body;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Copy the path',
            icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: widget.path)),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : _bytes == null
              ? const Center(child: CircularProgressIndicator())
              : _web != null
                  ? WebViewWidget(controller: _web!)
                  : _type!.startsWith('image/')
                      ? InteractiveViewer(maxScale: 8, child: Center(child: Image.memory(Uint8List.fromList(_bytes!))))
                      : _text != null
                          ? SingleChildScrollView(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(_text!, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)))
                          : Center(
                              child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text('$_name ($_type, ${_bytes!.length} bytes) can\'t be shown here.',
                                      textAlign: TextAlign.center))),
    );
  }
}
