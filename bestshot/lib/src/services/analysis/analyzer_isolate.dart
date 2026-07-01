import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';

import 'analysis_types.dart';
import 'modules/color_evaluator.dart';
import 'modules/exposure_evaluator.dart';
import 'modules/face_analyzer.dart';
import 'modules/feature_extractor.dart';
import 'modules/phash_calculator.dart';
import 'modules/sharpness_evaluator.dart';

class AnalyzerIsolate {
  static Future<List<AnalyzeOutput>> analyzeAll(
    List<AnalyzeInput> inputs, {
    DetectionMode mode = DetectionMode.standard,
    RootIsolateToken? rootIsolateToken,
    void Function(int done, int total)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    final isolate = await Isolate.spawn<_AnalyzerMessage>(
      _entry,
      _AnalyzerMessage(
        sendPort: receivePort.sendPort,
        inputs: inputs.map((i) {
          return _TransferableInput(key: i.key, filePath: i.filePath);
        }).toList(),
        mode: mode,
        rootIsolateToken: rootIsolateToken,
      ),
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );

    final results = <AnalyzeOutput>[];
    final completer = Completer<List<AnalyzeOutput>>();

    late StreamSubscription sub;
    late StreamSubscription errSub;
    late StreamSubscription exitSub;

    sub = receivePort.listen((message) {
      if (message is Map && message['type'] == 'result') {
        results.add(
          AnalyzeOutput(
            key: message['key'] as String,
            pHashHex: message['pHashHex'] as String,
            sharpness: (message['sharpness'] as num).toDouble(),
            exposureScore: (message['exposureScore'] as num).toDouble(),
            orbRows: (message['orbRows'] as num).toInt(),
            orbCols: (message['orbCols'] as num).toInt(),
            orbBytes: message['orbBytes'] as Uint8List,
            histogram: message['histogram'] as Uint8List,
            hueHistogram: message['hueHistogram'] as Float32List?,
            hasFace: (message['hasFace'] as bool?) ?? false,
            faceX: (message['faceX'] as num?)?.toInt() ?? 0,
            faceY: (message['faceY'] as num?)?.toInt() ?? 0,
            faceW: (message['faceW'] as num?)?.toInt() ?? 0,
            faceH: (message['faceH'] as num?)?.toInt() ?? 0,
            faceSharpness: (message['faceSharpness'] as num?)?.toDouble() ?? 0,
            eyeOpenAvg: (message['eyeOpenAvg'] as num?)?.toDouble() ?? -1,
            eyesClosed: (message['eyesClosed'] as bool?) ?? false,
            bothEyesDetected: (message['bothEyesDetected'] as bool?) ?? false,
            eyeSharpness: (message['eyeSharpness'] as num?)?.toDouble() ?? -1,
            debugGridSharps: (message['debugGridSharps'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList(),
          ),
        );
      }
      if (message is Map && message['type'] == 'progress') {
        final done = (message['done'] as num).toInt();
        final total = (message['total'] as num).toInt();
        onProgress?.call(done, total);
      }
      if (message is Map && message['type'] == 'done') {
        completer.complete(results);
      }
    });

    errSub = errorPort.listen((e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    });

    exitSub = exitPort.listen((_) {
      if (!completer.isCompleted) {
        completer.complete(results);
      }
    });

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
      await errSub.cancel();
      await exitSub.cancel();
      receivePort.close();
      errorPort.close();
      exitPort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static void _entry(_AnalyzerMessage message) {
    // Isolate.spawn の entrypoint は「void Function(T)」である必要があるため、
    // async を直接渡さずに内部の async 処理へ委譲する。
    _entryAsync(message);
  }

  static Future<void> _entryAsync(_AnalyzerMessage message) async {
    if (message.rootIsolateToken != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(
        message.rootIsolateToken!,
      );
    }

    final total = message.inputs.length;
    var done = 0;

    FaceDetector? faceDetector;
    Directory? tmpDir;

    if (message.mode == DetectionMode.portrait) {
      faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: true,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );
      tmpDir = await getTemporaryDirectory();
    }

    try {
      for (final input in message.inputs) {
        final out = await _analyzeOne(
          input.key,
          filePath: input.filePath,
          mode: message.mode,
          faceDetector: faceDetector,
          tmpDir: tmpDir,
        );
        message.sendPort.send({
          'type': 'result',
          'key': out.key,
          'pHashHex': out.pHashHex,
          'sharpness': out.sharpness,
          'exposureScore': out.exposureScore,
          'orbRows': out.orbRows,
          'orbCols': out.orbCols,
          'orbBytes': out.orbBytes,
          'histogram': out.histogram,
          'hueHistogram': out.hueHistogram,
          'hasFace': out.hasFace,
          'faceX': out.faceX,
          'faceY': out.faceY,
          'faceW': out.faceW,
          'faceH': out.faceH,
          'faceSharpness': out.faceSharpness,
          'eyeOpenAvg': out.eyeOpenAvg,
          'eyesClosed': out.eyesClosed,
          'bothEyesDetected': out.bothEyesDetected,
          'eyeSharpness': out.eyeSharpness,
          'debugGridSharps': out.debugGridSharps,
        });
        done++;
        message.sendPort.send({
          'type': 'progress',
          'done': done,
          'total': total,
        });
      }
    } finally {
      await faceDetector?.close();
    }

    message.sendPort.send({'type': 'done'});
  }

  static AnalyzeOutput _emptyOutput(String key) {
    return AnalyzeOutput(
      key: key,
      pHashHex: '0000000000000000',
      sharpness: 0,
      exposureScore: 0,
      orbRows: 0,
      orbCols: 0,
      orbBytes: Uint8List(0),
      histogram: Uint8List(256),
      hueHistogram: null,
      hasFace: false,
      faceX: 0,
      faceY: 0,
      faceW: 0,
      faceH: 0,
      faceSharpness: 0,
      eyeOpenAvg: -1,
      eyesClosed: false,
      bothEyesDetected: false,
      eyeSharpness: -1,
      debugGridSharps: null,
    );
  }

  static Future<AnalyzeOutput> _analyzeOne(
    String key, {
    String? filePath,
    required DetectionMode mode,
    FaceDetector? faceDetector,
    Directory? tmpDir,
  }) async {
    Uint8List rawBytes;
    if (filePath != null) {
      rawBytes = await File(filePath).readAsBytes();
    } else {
      rawBytes = Uint8List(0);
    }

    if (rawBytes.isEmpty) {
      return _emptyOutput(key);
    }

    cv.Mat? mat;
    cv.Mat? work;
    Uint8List? workBytes;

    try {
      mat = cv.imdecode(rawBytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return _emptyOutput(key);
      }

      // Resize for analysis (speed & accuracy)
      const maxEdge = 640;
      if (mat.cols > maxEdge || mat.rows > maxEdge) {
        final scale = maxEdge / (mat.cols > mat.rows ? mat.cols : mat.rows);
        work = cv.resize(mat, (
          (mat.cols * scale).round(),
          (mat.rows * scale).round(),
        ));
      } else {
        work = mat.clone();
      }

      // Some methods still use bytes, so encode once if needed.
      final encodeRes = cv.imencode(
        '.jpg',
        work,
        params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 90]),
      );
      workBytes = encodeRes.$2;

      final pHashHex = PHashCalculator.calcEqualizedPHashHexFromMat(work);
      final (fullSharpness, debugGridSharps) =
          SharpnessEvaluator.calcLaplacianVarianceFromMat(work, workBytes);
      final (exposure, histogram) =
          ExposureEvaluator.calcExposureAndHistogramFromMat(work);
      final hueHistogram = ColorEvaluator.calcHueHistogramFromMat(work);
      final orb = FeatureExtractor.calcOrbDescriptorsFromMat(work);

      var hasFace = false;
      var faceX = 0;
      var faceY = 0;
      var faceW = 0;
      var faceH = 0;
      var faceSharpness = 0.0;
      var eyeOpenAvg = -1.0;
      var eyesClosed = false;
      var bothEyesDetected = false;
      var eyeSharpness = -1.0;

      var sharpnessForScore = fullSharpness;

      if (mode == DetectionMode.portrait) {
        if (faceDetector != null && tmpDir != null) {
          final r = await FaceAnalyzer.portraitAnalyze(
            rawBytes, // Face detection on original for accuracy
            faceDetector: faceDetector,
            tmpDir: tmpDir,
          );
          hasFace = r.hasFace;
          faceX = r.faceX;
          faceY = r.faceY;
          faceW = r.faceW;
          faceH = r.faceH;
          faceSharpness = r.faceSharpness;
          eyeOpenAvg = r.eyeOpenAvg;
          eyesClosed = r.eyesClosed;
          bothEyesDetected = r.bothEyesDetected;
          eyeSharpness = r.eyeSharpness;
        }

        if (hasFace && faceSharpness > 0) {
          sharpnessForScore = faceSharpness;
        }
        if (eyeSharpness > 0) {
          sharpnessForScore = (sharpnessForScore * 0.4) + (eyeSharpness * 0.6);
        }
        if (eyesClosed) {
          sharpnessForScore *= 0.2;
        }
      }

      return AnalyzeOutput(
        key: key,
        pHashHex: pHashHex,
        sharpness: sharpnessForScore,
        exposureScore: exposure,
        orbRows: orb.rows,
        orbCols: orb.cols,
        orbBytes: orb.bytes,
        histogram: histogram,
        hueHistogram: hueHistogram,
        hasFace: hasFace,
        faceX: faceX,
        faceY: faceY,
        faceW: faceW,
        faceH: faceH,
        faceSharpness: faceSharpness,
        eyeOpenAvg: eyeOpenAvg,
        eyesClosed: eyesClosed,
        bothEyesDetected: bothEyesDetected,
        eyeSharpness: eyeSharpness,
        debugGridSharps: debugGridSharps,
      );
    } catch (e, stack) {
      debugPrint('Isolate analysis error for key $key: $e\n$stack');
      return _emptyOutput(key);
    } finally {
      mat?.dispose();
      work?.dispose();
    }
  }
}

class _AnalyzerMessage {
  _AnalyzerMessage({
    required this.sendPort,
    required this.inputs,
    required this.mode,
    required this.rootIsolateToken,
  });

  final SendPort sendPort;
  final List<_TransferableInput> inputs;
  final DetectionMode mode;
  final RootIsolateToken? rootIsolateToken;
}

class _TransferableInput {
  _TransferableInput({required this.key, this.filePath});
  final String key;
  final String? filePath;
}
