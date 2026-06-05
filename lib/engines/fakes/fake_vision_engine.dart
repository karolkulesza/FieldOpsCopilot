import 'dart:typed_data';

import '../vision_engine.dart';

/// Deterministic [VisionEngine] that returns a scripted result regardless of
/// the input image. Used for unit tests and the skeleton UI.
class FakeVisionEngine implements VisionEngine {
  FakeVisionEngine({VisionResult? result})
    : _result =
          result ??
          const VisionResult(
            barcodes: ['SKU-BRK-990'],
            text: 'MODEL: APEX-9 SERIAL: 8892',
          );

  final VisionResult _result;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async {
    _ready = true;
  }

  @override
  Future<VisionResult> analyze(Uint8List imageBytes) async {
    if (!_ready) {
      throw StateError('FakeVisionEngine.analyze called before initialize()');
    }
    return _result;
  }

  @override
  Future<void> dispose() async {
    _ready = false;
  }
}
