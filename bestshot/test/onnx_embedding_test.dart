import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:bestshot/src/services/analysis/embedding_service.dart';
import 'package:bestshot/src/services/analysis/embedding_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'worker reuses cache without decoding and recovers a corrupt entry',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'bestshot_worker_cache_',
      );
      try {
        final image = img.Image(224, 224);
        img.fill(image, img.getColor(200, 50, 50));
        final source = File(p.join(temp.path, 'image.jpg'));
        await source.writeAsBytes(img.encodeJpg(image));
        final modelPath = p.join(
          Directory.current.path,
          'assets',
          'models',
          'embedding.onnx',
        );
        final modelStat = await File(modelPath).stat();
        final cache = EmbeddingCache(
          Directory(p.join(temp.path, 'cache')),
          '${File(modelPath).absolute.path}|${modelStat.size}|${modelStat.modified.microsecondsSinceEpoch}',
          true,
        );
        final key = cache.fingerprint(source.path, await source.stat());
        final sentinel = <String, Float32List>{
          for (final crop in ['full', 'center', 'left', 'right'])
            crop: Float32List(576)..[0] = 1,
        };
        await cache.write(source.path, key, sentinel);
        final hit = await extractEmbeddingBatch(
          modelPath: modelPath,
          images: [(source.path, Uint8List(0))],
          isLightweight: true,
          cacheDirectory: cache.directory.path,
        );
        expect(hit.single?.embeddings['full'], sentinel['full']);
        final file = (await cache.directory.list().toList()).single as File;
        await file.writeAsString('corrupt');
        final repaired = await extractEmbeddingBatch(
          modelPath: modelPath,
          images: [(source.path, Uint8List(0))],
          isLightweight: true,
          cacheDirectory: cache.directory.path,
        );
        expect(repaired.single?.embeddings['full']?.length, 576);
        expect(await cache.read(source.path, key), isNotNull);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'worker batch extracts vectors and tolerates an unreadable image',
    () async {
      final image = img.Image(224, 224);
      img.fill(image, img.getColor(200, 50, 50));
      final result = await extractEmbeddingBatch(
        modelPath: p.join(
          Directory.current.path,
          'assets',
          'models',
          'embedding.onnx',
        ),
        images: [
          (null, Uint8List.fromList(img.encodeJpg(image))),
          (p.join(Directory.current.path, 'missing-photo.jpg'), Uint8List(0)),
        ],
        isLightweight: true,
      );
      expect(result.length, 2);
      expect(result.first?.embeddings['full']?.length, 576);
      expect(result.last, isNull);
    },
  );

  test(
    'WindowsOnnxEmbeddingService loads embedding.onnx and extracts valid normalized embeddings',
    () async {
      final modelPath = p.join(
        Directory.current.path,
        'assets',
        'models',
        'embedding.onnx',
      );
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
        expect(
          fullEmb.length,
          equals(576),
          reason: 'MobileNetV3-Small features are 576-dim',
        );

        // Verify L2 normalization (norm should be ~1.0)
        double normSq = 0.0;
        for (final v in fullEmb) {
          normSq += v * v;
        }
        expect(
          normSq,
          closeTo(1.0, 0.01),
          reason: 'Embedding vectors must be L2 normalized',
        );
      } finally {
        service.dispose();
      }
    },
  );
}
