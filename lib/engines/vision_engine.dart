/// Abstraction over on-device computer vision (barcode + text OCR).
library;

import 'dart:typed_data';

/// The result of analysing a single image frame.
class VisionResult {
  const VisionResult({this.barcodes = const [], this.text = ''});

  /// Decoded barcode / QR payloads.
  final List<String> barcodes;

  /// Recognised free text (OCR).
  final String text;

  @override
  String toString() => 'VisionResult(barcodes: $barcodes, text: "$text")';
}

/// Contract implemented by every vision backend (fake or on-device).
abstract interface class VisionEngine {
  Future<void> initialize();

  bool get isReady;

  /// Analyses raw image bytes and returns decoded barcodes and OCR text.
  Future<VisionResult> analyze(Uint8List imageBytes);

  Future<void> dispose();
}
