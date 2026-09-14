import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:bestshot/src/services/analysis/embedding_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WindowsOnnxEmbeddingService loads embedding.onnx and extracts valid normalized embeddings', () async {
    final modelPath = p.join(Directory.current.path, 'assets', 'models', 'embedding.onnx');
    final modelFile = File(modelPath);

    if (!modelFile.existsSync()) {
      fail('embedding.onnx not found at $modelPath');
    }

    final service = WindowsOnnxEmbeddingService(modelPath: modelPath);
    final initOk = await service.initialize();
    expect(initOk, isTrue, reason: 'ONNX model initialization must succeed');
    expect(service.isAvailable, isTrue);

    try {
      // Create a test image
      final testImg = img.Image(224, 224);
      final red = img.getColor(200, 50, 50);
      final blue = img.getColor(50, 50, 200);
      img.fill(testImg, red);
      img.fillCircle(testImg, 112, 112, 40, blue);
      final jpgBytes = img.encodeJpg(testImg);

      // Extract embeddings (desktop: 6 multi-crops)
      final result = await service.extractEmbeddings(
        Uint8List.fromList(jpgBytes),
        isLightweight: false,
      );
      expect(result, isNotNull);
      expect(result!.embeddings, isNotEmpty);
      expect(result.embeddings.containsKey('full'), isTrue);
      expect(result.embeddings.containsKey('center'), isTrue);

      final fullEmb = result.embeddings['full']!;
      expect(fullEmb.length, equals(576), reason: 'MobileNetV3-Small features are 576-dim');

      // Verify L2 normalization (norm should be ~1.0)
      double normSq = 0.0;
      for (final v in fullEmb) {
        normSq += v * v;
      }
      expect(normSq, closeTo(1.0, 0.01), reason: 'Embedding vectors must be L2 normalized');
    } finally {
      service.dispose();
    }
  });
}
