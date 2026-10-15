import 'package:flutter/services.dart';

/// ImageIO decodes iPhone HEIC/HEIF images that OpenCV cannot read.
class IosImageDecoder {
  static const _channel = MethodChannel('com.example.bestshot/vision');

  static bool needsNativeDecoder(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.heic') || lower.endsWith('.heif');
  }

  static Future<Uint8List> decode(String path, {int maxEdge = 1920}) async {
    final bytes = await _channel.invokeMethod<Uint8List>('decodeImage', {
      'path': path,
      'maxEdge': maxEdge,
    });
    if (bytes == null || bytes.isEmpty) {
      throw StateError('HEIF画像を読み込めませんでした: $path');
    }
    return bytes;
  }
}
