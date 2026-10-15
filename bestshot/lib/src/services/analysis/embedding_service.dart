import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'embedding_cache.dart';

/// Result of an embedding extraction across multiple crops
class EmbeddingResult {
  EmbeddingResult(this.embeddings);

  /// Key is region name: 'full', 'center', 'tl', 'tr', 'bl', 'br' (or 'left', 'right')
  final Map<String, Float32List> embeddings;
}

/// A bounded batch owns its native ONNX session in a worker isolate. Only
/// paths/thumbnails and plain vectors cross the isolate boundary.
Future<List<EmbeddingResult?>> extractEmbeddingBatch({
  required String modelPath,
  required List<(String?, Uint8List)> images,
  required bool isLightweight,
  String? cacheDirectory,
}) => Isolate.run(() async {
  final service = OnnxEmbeddingService(modelPath: modelPath);
  try {
    final modelStat = await File(modelPath).stat();
    final cache = cacheDirectory == null
        ? null
        : EmbeddingCache(
            Directory(cacheDirectory),
            '${File(modelPath).absolute.path}|${modelStat.size}|${modelStat.modified.microsecondsSinceEpoch}',
            isLightweight,
          );
    bool? initialized;
    final results = <EmbeddingResult?>[];
    for (final image in images) {
      try {
        final stat = image.$1 == null ? null : await File(image.$1!).stat();
        final fingerprint = stat == null || cache == null
            ? null
            : cache.fingerprint(image.$1!, stat);
        final cached = fingerprint == null
            ? null
            : await cache!.read(image.$1!, fingerprint);
        if (cached != null) {
          results.add(EmbeddingResult(cached));
          continue;
        }
        initialized ??= await service.initialize();
        if (!initialized) {
          results.add(null);
          continue;
        }
        final bytes = image.$1 == null || image.$2.isNotEmpty
            ? image.$2
            : await File(image.$1!).readAsBytes();
        final result = await service.extractEmbeddings(
          bytes,
          isLightweight: isLightweight,
        );
        results.add(result);
        // Never save vectors if the source changed during inference.
        if (result != null && fingerprint != null) {
          try {
            final after = await File(image.$1!).stat();
            if (cache!.fingerprint(image.$1!, after) == fingerprint) {
              await cache.write(image.$1!, fingerprint, result.embeddings);
            }
          } catch (_) {
            /* Source/cache changes must not duplicate a result. */
          }
        }
      } catch (e) {
        debugPrint('[Embedding] Image unavailable: $e');
        results.add(null);
      }
    }
    return results;
  } finally {
    service.dispose();
  }
});

/// Abstract interface for Embedding extraction
abstract class EmbeddingService {
  bool get isAvailable;

  /// Initializes the model (loads from disk etc.)
  Future<bool> initialize();

  /// Extracts multi-crop embeddings from raw image bytes.
  /// If [isLightweight] is true, extracts 4 crops instead of 6.
  Future<EmbeddingResult?> extractEmbeddings(
    Uint8List imageBytes, {
    bool isLightweight = false,
  });

  void dispose();
}

/// ONNX-based embedding service
/// Input specification:
/// - Input Shape: [1, 3, 224, 224] (NCHW, RGB)
/// - Normalization: ImageNet mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]
/// - Output: L2-normalized float32 vector
class OnnxEmbeddingService implements EmbeddingService {
  OrtSession? _session;
  final String modelPath;
  String? _inputName;
  bool _initialized = false;

  OnnxEmbeddingService({required this.modelPath});

  @override
  bool get isAvailable => _initialized && _session != null;

  @override
  Future<bool> initialize() async {
    if (isAvailable) return true;
    try {
      final file = File(modelPath);
      if (!await file.exists()) {
        debugPrint(
          '[EmbeddingService] Model file not found at: $modelPath. Safe fallback active.',
        );
        _initialized = false;
        return false;
      }

      OrtEnv.instance.init();
      final sessionOptions = OrtSessionOptions();
      try {
        final modelBytes = await file.readAsBytes();
        _session = OrtSession.fromBuffer(modelBytes, sessionOptions);
      } finally {
        sessionOptions.release();
      }

      // Retrieve first input name dynamically if available
      final inputs = _session?.inputNames;
      if (inputs != null && inputs.length == 1 && _session!.outputCount == 1) {
        _inputName = inputs.first;
      } else {
        throw StateError('Embedding model must have one input and one output');
      }

      // Probe shape/layout and feature-vector size before advertising availability.
      if (_runInferenceOnCrop(img.Image(224, 224)) == null) {
        throw StateError(
          'Expected NCHW 224 RGB input and 576-dimensional features',
        );
      }

      _initialized = true;
      debugPrint(
        '[EmbeddingService] Successfully loaded ONNX model: $modelPath (input: $_inputName)',
      );
      return true;
    } catch (e) {
      debugPrint(
        '[EmbeddingService] Initialization failed: $e. Graceful fallback active.',
      );
      dispose();
      return false;
    }
  }

  @override
  Future<EmbeddingResult?> extractEmbeddings(
    Uint8List imageBytes, {
    bool isLightweight = false,
  }) async {
    if (!isAvailable || _session == null) return null;

    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;
      final decoded = img.bakeOrientation(image);

      final w = decoded.width;
      final h = decoded.height;
      if (w <= 0 || h <= 0) return null;

      final crops = <String, img.Image>{};

      // 1. Full image
      crops['full'] = img.copyResize(decoded, width: 224, height: 224);

      if (!isLightweight) {
        // Full quality - 6 multi-crops
        // Center 60%
        final cw = (w * 0.60).round();
        final ch = (h * 0.60).round();
        final cx = ((w - cw) / 2).round();
        final cy = ((h - ch) / 2).round();
        crops['center'] = img.copyResize(
          img.copyCrop(decoded, cx, cy, cw, ch),
          width: 224,
          height: 224,
        );

        // Top-Left (0..60%, 0..60%)
        crops['tl'] = img.copyResize(
          img.copyCrop(decoded, 0, 0, cw, ch),
          width: 224,
          height: 224,
        );

        // Top-Right
        crops['tr'] = img.copyResize(
          img.copyCrop(decoded, w - cw, 0, cw, ch),
          width: 224,
          height: 224,
        );

        // Bottom-Left
        crops['bl'] = img.copyResize(
          img.copyCrop(decoded, 0, h - ch, cw, ch),
          width: 224,
          height: 224,
        );

        // Bottom-Right
        crops['br'] = img.copyResize(
          img.copyCrop(decoded, w - cw, h - ch, cw, ch),
          width: 224,
          height: 224,
        );
      } else {
        // Memory-efficient inference - 4 crops
        final cw = (w * 0.60).round();
        final ch = (h * 0.60).round();
        final cx = ((w - cw) / 2).round();
        final cy = ((h - ch) / 2).round();
        crops['center'] = img.copyResize(
          img.copyCrop(decoded, cx, cy, cw, ch),
          width: 224,
          height: 224,
        );

        // Left half
        crops['left'] = img.copyResize(
          img.copyCrop(decoded, 0, 0, (w * 0.65).round(), h),
          width: 224,
          height: 224,
        );

        // Right half
        crops['right'] = img.copyResize(
          img.copyCrop(decoded, (w * 0.35).round(), 0, (w * 0.65).round(), h),
          width: 224,
          height: 224,
        );
      }

      final embeddings = <String, Float32List>{};
      for (final entry in crops.entries) {
        final vector = _runInferenceOnCrop(entry.value);
        if (vector != null && vector.isNotEmpty) {
          embeddings[entry.key] = vector;
        }
      }

      if (embeddings.isEmpty) return null;
      return EmbeddingResult(embeddings);
    } catch (e) {
      debugPrint('[EmbeddingService] Inference error: $e');
      return null;
    }
  }

  Float32List? _runInferenceOnCrop(img.Image crop) {
    if (_session == null) return null;

    OrtRunOptions? runOptions;
    OrtValueTensor? inputTensor;
    List<OrtValue?>? outputs;

    try {
      // Convert img.Image to NCHW [1, 3, 224, 224] with ImageNet normalization
      const targetSize = 224;
      const planeSize = targetSize * targetSize;
      final tensorData = Float32List(1 * 3 * planeSize);

      const meanR = 0.485, meanG = 0.456, meanB = 0.406;
      const stdR = 0.229, stdG = 0.224, stdB = 0.225;

      final rOffset = 0;
      final gOffset = planeSize;
      final bOffset = planeSize * 2;

      for (var y = 0; y < targetSize; y++) {
        for (var x = 0; x < targetSize; x++) {
          final pixel = crop.getPixel(x, y);
          final r = img.getRed(pixel) / 255.0;
          final g = img.getGreen(pixel) / 255.0;
          final b = img.getBlue(pixel) / 255.0;

          final idx = y * targetSize + x;
          tensorData[rOffset + idx] = (r - meanR) / stdR;
          tensorData[gOffset + idx] = (g - meanG) / stdG;
          tensorData[bOffset + idx] = (b - meanB) / stdB;
        }
      }

      inputTensor = OrtValueTensor.createTensorWithDataList(tensorData, [
        1,
        3,
        targetSize,
        targetSize,
      ]);
      runOptions = OrtRunOptions();

      final inputName = _inputName ?? 'input';
      outputs = _session!.run(runOptions, {inputName: inputTensor});

      if (outputs.isEmpty || outputs[0] == null) {
        return null;
      }

      final rawList = outputs[0]!.value;
      if (rawList is! List) return null;

      // Flatten output if nested (e.g. [[v1, v2, ...]])
      final flatValues = <double>[];
      void flatten(dynamic item) {
        if (item is num) {
          flatValues.add(item.toDouble());
        } else if (item is List) {
          for (final sub in item) {
            flatten(sub);
          }
        }
      }

      flatten(rawList);

      if (flatValues.length != EmbeddingCache.dimensions ||
          flatValues.any((value) => !value.isFinite)) {
        return null;
      }

      // L2 Normalization
      double normSq = 0.0;
      for (final val in flatValues) {
        normSq += val * val;
      }
      final norm = math.sqrt(normSq);
      if (!norm.isFinite || norm <= 0) return null;
      final l2Normalized = Float32List(flatValues.length);
      for (var i = 0; i < flatValues.length; i++) {
        l2Normalized[i] = norm > 0 ? (flatValues[i] / norm) : 0.0;
      }

      return l2Normalized;
    } catch (e) {
      debugPrint('[EmbeddingService] _runInferenceOnCrop failed: $e');
      return null;
    } finally {
      inputTensor?.release();
      runOptions?.release();
      if (outputs != null) {
        for (final out in outputs) {
          out?.release();
        }
      }
    }
  }

  @override
  void dispose() {
    final session = _session;
    _session = null;
    _initialized = false;
    try {
      session?.release();
    } catch (_) {}
  }
}
