import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;

/// Result of an embedding extraction across multiple crops
class EmbeddingResult {
  EmbeddingResult(this.embeddings);
  
  /// Key is region name: 'full', 'center', 'tl', 'tr', 'bl', 'br' (or 'left', 'right')
  final Map<String, Float32List> embeddings;
}

/// Abstract interface for Embedding extraction
abstract class EmbeddingService {
  bool get isAvailable;

  /// Initializes the model (loads from disk etc.)
  Future<bool> initialize();

  /// Extracts multi-crop embeddings from raw image bytes.
  /// If [isLightweight] is true, extracts 4 crops instead of 6.
  Future<EmbeddingResult?> extractEmbeddings(Uint8List imageBytes, {bool isLightweight = false});
  
  void dispose();
}

/// ONNX-based embedding service
/// Input specification:
/// - Input Shape: [1, 3, 224, 224] (NCHW, RGB)
/// - Normalization: ImageNet mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]
/// - Output: L2-normalized float32 vector
class WindowsOnnxEmbeddingService implements EmbeddingService {
  OrtSession? _session;
  final String modelPath;
  String? _inputName;
  bool _initialized = false;

  WindowsOnnxEmbeddingService({required this.modelPath});

  @override
  bool get isAvailable => _initialized && _session != null;

  @override
  Future<bool> initialize() async {
    try {
      final file = File(modelPath);
      if (!await file.exists()) {
        debugPrint('[EmbeddingService] Model file not found at: $modelPath. Safe fallback active.');
        _initialized = false;
        return false;
      }
      
      OrtEnv.instance.init();
      final sessionOptions = OrtSessionOptions();
      _session = OrtSession.fromFile(file, sessionOptions);
      sessionOptions.release();

      // Retrieve first input name dynamically if available
      final inputs = _session?.inputNames;
      if (inputs != null && inputs.isNotEmpty) {
        _inputName = inputs.first;
      } else {
        _inputName = 'input';
      }

      _initialized = true;
      debugPrint('[EmbeddingService] Successfully loaded ONNX model: $modelPath (input: $_inputName)');
      return true;
    } catch (e) {
      debugPrint('[EmbeddingService] Initialization failed: $e. Graceful fallback active.');
      _initialized = false;
      _session = null;
      return false;
    }
  }

  @override
  Future<EmbeddingResult?> extractEmbeddings(Uint8List imageBytes, {bool isLightweight = false}) async {
    if (!isAvailable || _session == null) return null;

    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;

      final w = decoded.width;
      final h = decoded.height;
      if (w <= 0 || h <= 0) return null;

      final crops = <String, img.Image>{};

      // 1. Full image
      crops['full'] = img.copyResize(decoded, width: 224, height: 224);

      if (!isLightweight) {
        // Windows (Desktop) - 6 Multi-crops
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
        // Android (Mobile) - 4 Lightweight crops
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

      inputTensor = OrtValueTensor.createTensorWithDataList(
        tensorData,
        [1, 3, targetSize, targetSize],
      );
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

      if (flatValues.isEmpty) return null;

      // L2 Normalization
      double normSq = 0.0;
      for (final val in flatValues) {
        normSq += val * val;
      }
      final norm = math.sqrt(normSq);
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
    try {
      _session?.release();
      _session = null;
      _initialized = false;
    } catch (_) {}
  }
}
