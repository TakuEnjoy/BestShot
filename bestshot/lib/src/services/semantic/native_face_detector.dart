import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeFace {
  final double? smilingProbability;
  final double? leftEyeOpenProbability;
  final double? rightEyeOpenProbability;
  final double x, y, width, height; // bounding box normalized 0..1

  NativeFace({
    this.smilingProbability,
    this.leftEyeOpenProbability,
    this.rightEyeOpenProbability,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

class NativeFaceDetector {
  static const MethodChannel _channel = MethodChannel('com.example.bestshot/vision');

  Future<void> close() async {
    // No-op for now
  }

  Future<List<NativeFace>> processImage(String filePath) async {
    try {
      final result = await _channel.invokeMethod('detectFaces', {'path': filePath});
      if (result == null) return [];
      
      final faces = <NativeFace>[];
      for (final item in (result as List)) {
        final map = item as Map;
        faces.add(NativeFace(
          smilingProbability: map['smilingProbability'] as double?,
          leftEyeOpenProbability: map['leftEyeOpenProbability'] as double?,
          rightEyeOpenProbability: map['rightEyeOpenProbability'] as double?,
          x: map['x'] as double? ?? 0.0,
          y: map['y'] as double? ?? 0.0,
          width: map['width'] as double? ?? 0.0,
          height: map['height'] as double? ?? 0.0,
        ));
      }
      return faces;
    } catch (e) {
      debugPrint('Error detecting faces: $e');
      return [];
    }
  }
}
