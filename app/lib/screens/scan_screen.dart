import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Camera view that returns the first Goblin pairing link it sees in a QR code (`goblin pair` or a Goblin page).
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _cam = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _other;

  @override
  void dispose() {
    _cam.dispose();
    super.dispose();
  }

  void _seen(BarcodeCapture c) {
    if (_done) return;
    for (final b in c.barcodes) {
      final v = b.rawValue?.trim() ?? '';
      if (v.startsWith('goblin://pair/')) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
      if (v.isNotEmpty && v != _other) setState(() => _other = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the pairing QR code')),
      body: Stack(children: [
        MobileScanner(
          controller: _cam,
          onDetect: _seen,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(error.errorCode == MobileScannerErrorCode.permissionDenied
                  ? 'Switchboard needs the camera to scan the code. Allow it in Android settings, or paste the link instead.'
                  : 'The camera did not start: ${error.errorCode.name}. Paste the link instead.',
                  textAlign: TextAlign.center),
            ),
          ),
        ),
        if (_other != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('That QR code is not a Goblin pairing link. Run `goblin pair` and scan its code.',
                    style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
      ]),
    );
  }
}
