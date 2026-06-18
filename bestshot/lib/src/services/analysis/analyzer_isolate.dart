import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_compare/image_compare.dart' as ic;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'analysis_types.dart';

class AnalyzerIsolate {
  static Future<List<AnalyzeOutput>> analyzeAll(
    List<AnalyzeInput> inputs, {
    DetectionMode mode = DetectionMode.standard,
    RootIsolateToken? rootIsolateToken,
    void Function(int done, int total)? onProgress,
  }) async {
    if (mode == DetectionMode.portrait && Platform.isWindows) {
      final support = await getApplicationSupportDirectory();
      final cascadeDir = Directory(p.join(support.path, 'cascades'));
      if (!await cascadeDir.exists()) {
        await cascadeDir.create(recursive: true);
      }
      await _ensureAssetFile(
        assetPath: 'assets/cascades/haarcascade_frontalface_default.xml',
        outPath: p.join(cascadeDir.path, 'haarcascade_frontalface_default.xml'),
      );
      await _ensureAssetFile(
        assetPath: 'assets/cascades/haarcascade_eye.xml',
        outPath: p.join(cascadeDir.path, 'haarcascade_eye.xml'),
      );
    }

    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    final isolate = await Isolate.spawn<_AnalyzerMessage>(
      _entry,
      _AnalyzerMessage(
        sendPort: receivePort.sendPort,
        inputs: inputs.map((i) {
          if (i.displayBytes != null && i.filePath == null) {
            return _TransferableInput(
              key: i.key,
              data: TransferableTypedData.fromList([i.displayBytes!]),
            );
          } else {
            return _TransferableInput(key: i.key, filePath: i.filePath);
          }
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
            debugGridSharps: (message['debugGridSharps'] as List?)?.map((e) => (e as num).toDouble()).toList(),
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

    final isAndroid = Platform.isAndroid;
    final isWindows = Platform.isWindows;

    FaceDetector? faceDetector;
    Directory? tmpDir;
    cv.CascadeClassifier? faceCascade;
    cv.CascadeClassifier? eyeCascade;

    if (message.mode == DetectionMode.portrait && isAndroid) {
      faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: true,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );
      tmpDir = await getTemporaryDirectory();
    }

    if (message.mode == DetectionMode.portrait && isWindows) {
      final support = await getApplicationSupportDirectory();
      final cascadeDir = Directory(p.join(support.path, 'cascades'));
      final facePath = p.join(cascadeDir.path, 'haarcascade_frontalface_default.xml');
      final eyePath = p.join(cascadeDir.path, 'haarcascade_eye.xml');
      faceCascade = cv.CascadeClassifier.fromFile(facePath);
      eyeCascade = cv.CascadeClassifier.fromFile(eyePath);
    }

    try {
      for (final input in message.inputs) {
        final bytes = input.data?.materialize().asUint8List();
        final out = await _analyzeOne(
          input.key,
          bytes,
          filePath: input.filePath,
          mode: message.mode,
          faceDetector: faceDetector,
          tmpDir: tmpDir,
          faceCascade: faceCascade,
          eyeCascade: eyeCascade,
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
    String key,
    Uint8List? displayBytes, {
    String? filePath,
    required DetectionMode mode,
    FaceDetector? faceDetector,
    Directory? tmpDir,
    cv.CascadeClassifier? faceCascade,
    cv.CascadeClassifier? eyeCascade,
  }) async {
    Uint8List rawBytes;
    if (filePath != null) {
      rawBytes = await File(filePath).readAsBytes();
    } else {
      rawBytes = displayBytes ?? Uint8List(0);
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

      final pHashHex = _calcEqualizedPHashHexFromMat(work);
      final (fullSharpness, debugGridSharps) = _calcLaplacianVarianceFromMat(work, workBytes);
      final (exposure, histogram) = _calcExposureAndHistogramFromMat(work);
      final hueHistogram = _calcHueHistogramFromMat(work);
      final orb = _calcOrbDescriptorsFromMat(work);

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
        if (Platform.isAndroid && faceDetector != null && tmpDir != null) {
          final r = await _portraitAnalyzeAndroid(
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
        } else if (Platform.isWindows &&
            faceCascade != null &&
            eyeCascade != null) {
          final r = _portraitAnalyzeWindowsFromMat(
            mat, // Use original for Windows detection accuracy
            faceCascade: faceCascade,
            eyeCascade: eyeCascade,
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
      print('Isolate analysis error for key $key: $e\n$stack');
      return _emptyOutput(key);
    } finally {
      mat?.dispose();
      work?.dispose();
    }
  }

  static String _calcEqualizedPHashHexFromMat(cv.Mat mat) {
    try {
      final small = cv.resize(mat, (32, 32));
      final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      final eq = cv.equalizeHist(gray);

      final pixels = <ic.Pixel>[];
      final data = eq.data;
      for (final v in data) {
        pixels.add(ic.Pixel(v, v, v, 255));
      }

      small.dispose();
      gray.dispose();
      eq.dispose();

      final dynamicPixelList = <dynamic>[...pixels];
      final hex = ic.PerceptualHash().calcPhash(dynamicPixelList);
      return hex.padLeft(16, '0');
    } catch (e, s) {
      print('Error in _calcEqualizedPHashHexFromMat: $e\n$s');
      return '0000000000000000';
    }
  }

  static (double, List<double>) _calcLaplacianVarianceFromMat(cv.Mat bgr, Uint8List? bytes) {
    cv.Mat? gray;
    try {
      if (bgr.isEmpty) return (0.0, List.filled(16, 0.0));
      gray = cv.cvtColor(bgr, cv.COLOR_BGR2GRAY);

      final rows = gray.rows;
      final cols = gray.cols;
      final blockH = rows ~/ 4;
      final blockW = cols ~/ 4;

      if (blockH <= 0 || blockW <= 0) {
        cv.Mat? lap;
        try {
          lap = cv.laplacian(gray, cv.MatType.CV_64F);
          final (_, stddev) = cv.meanStdDev(lap);
          final v = stddev.val1 * stddev.val1;
          final out = (v.isFinite ? v : 0.0).toDouble();
          return (out, List.filled(16, out));
        } finally {
          lap?.dispose();
        }
      }

      final variances = <double>[];
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          final y = r * blockH;
          final x = c * blockW;
          final w = (c == 3) ? (cols - x) : blockW;
          final h = (r == 3) ? (rows - y) : blockH;

          cv.Mat? sub;
          cv.Mat? lap;
          try {
            final rect = cv.Rect(x, y, w, h);
            sub = gray.region(rect);
            if (sub.isEmpty) {
              variances.add(0.0);
              continue;
            }
            lap = cv.laplacian(sub, cv.MatType.CV_64F);
            final (_, stddev) = cv.meanStdDev(lap);
            var v = stddev.val1 * stddev.val1;
            if (!v.isFinite) v = 0.0;

            // Apply center-weighted composition priority
            if ((r == 1 || r == 2) && (c == 1 || c == 2)) {
              v *= 1.15; // Center region focus
            }

            variances.add(v.toDouble());
          } catch (e) {
            print('Error in cell _calcLaplacianVarianceFromMat: $e');
            variances.add(0.0);
          } finally {
            sub?.dispose();
            lap?.dispose();
          }
        }
      }

      // Find top 4 blocks to calculate subject focused average sharpness
      final sorted = List<double>.from(variances)..sort((a, b) => b.compareTo(a));
      final topAvg = (sorted[0] + sorted[1] + sorted[2] + sorted[3]) / 4.0;

      return (topAvg.isFinite ? topAvg : 0.0, variances);
    } catch (e, s) {
      print('Error in _calcLaplacianVarianceFromMat: $e\n$s');
      final fb = bytes != null ? _fallbackLaplacianVariance(bytes) : 0.0;
      return (fb, List.filled(16, fb));
    } finally {
      gray?.dispose();
    }
  }

  static (double, Uint8List) _calcExposureAndHistogramFromMat(cv.Mat bgr) {
    cv.Mat? gray;
    cv.Mat? hist;
    try {
      gray = cv.cvtColor(bgr, cv.COLOR_BGR2GRAY);

      hist = cv.calcHist(
        cv.VecMat.fromList([gray]),
        cv.VecI32.fromList([0]),
        cv.Mat.empty(),
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      final data = hist.data;
      if (data.isEmpty) return (0.0, Uint8List(256));

      double maxVal = 0;
      for (var i = 0; i < data.length; i++) {
        final v = data[i].toDouble();
        if (v > maxVal) maxVal = v;
      }
      final normHist = Uint8List(256);
      if (maxVal > 0) {
        for (var i = 0; i < 256; i++) {
          normHist[i] = ((data[i].toDouble() / maxVal) * 255).round();
        }
      }

      double sum = 0;
      for (final v in data) {
        sum += v;
      }
      if (sum <= 0) return (0.0, normHist);

      double clipLow = 0;
      for (var i = 0; i <= 5; i++) {
        clipLow += data[i];
      }
      double clipHigh = 0;
      for (var i = 250; i < 256; i++) {
        clipHigh += data[i];
      }
      final clip = (clipLow + clipHigh) / sum;

      final (mean, _) = cv.meanStdDev(gray);
      final meanVal = mean.val1;
      final meanPenalty = (meanVal - 127.0).abs() / 127.0;

      // 露出の偏りペナルティの重みを 0.35 ➔ 0.15 へ緩和（意図的なローキー・ハイキーの保護）
      final score = (1.0 - clip) * (1.0 - (meanPenalty * 0.15));
      return (score.clamp(0.0, 1.0), normHist);
    } catch (e, s) {
      print('Error in _calcExposureAndHistogramFromMat: $e\n$s');
      return (0.0, Uint8List(256));
    } finally {
      gray?.dispose();
      hist?.dispose();
    }
  }

  static _OrbDesc _calcOrbDescriptorsFromMat(cv.Mat mat) {
    cv.Mat? gray;
    cv.Mat? eq;
    cv.Mat? desc;
    try {
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
      eq = cv.equalizeHist(gray);

      final orb = cv.ORB.create(nFeatures: 600, scaleFactor: 1.2, nLevels: 8);
      final result = orb.detectAndCompute(eq, cv.Mat.empty());
      desc = result.$2;
      if (desc.isEmpty) return _OrbDesc.empty();
      final rows = desc.rows > 256 ? 256 : desc.rows;
      final cols = desc.cols;
      final elemSize = desc.elemSize;
      final bytesLen = rows * cols * elemSize;
      final all = desc.data;
      if (all.length < bytesLen) return _OrbDesc.empty();
      final sliced = Uint8List.fromList(all.sublist(0, bytesLen));
      return _OrbDesc(rows: rows, cols: cols, bytes: sliced);
    } catch (e, s) {
      print('Error in _calcOrbDescriptorsFromMat: $e\n$s');
      return _OrbDesc.empty();
    } finally {
      gray?.dispose();
      eq?.dispose();
      desc?.dispose();
    }
  }

  static Float32List? _calcHueHistogramFromMat(cv.Mat bgr) {
    cv.Mat? hsv;
    cv.Mat? mask;
    cv.Mat? maskS;
    cv.Mat? maskV;
    cv.Mat? histH;
    cv.Mat? histS;
    cv.Mat? histV;
    cv.Mat? histHNorm;
    cv.Mat? histSNorm;
    cv.Mat? histVNorm;
    cv.Mat? centerMat;
    try {
      if (bgr.isEmpty) return null;

      // Crop to central 50% region to focus on the subject and reduce background influence
      final cx = bgr.cols ~/ 4;
      final cy = bgr.rows ~/ 4;
      final cw = bgr.cols ~/ 2;
      final ch = bgr.rows ~/ 2;
      centerMat = bgr.region(cv.Rect(cx, cy, cw, ch));

      hsv = cv.cvtColor(centerMat, cv.COLOR_BGR2HSV);
      final channels = cv.split(hsv);
      final S = channels[1];
      final V = channels[2];

      // SとVの最大値を取得して適応的にしきい値を決定する
      final sData = S.data;
      final vData = V.data;

      var maxS = 0;
      for (var i = 0; i < sData.length; i++) {
        if (sData[i] > maxS) maxS = sData[i];
      }
      var maxV = 0;
      for (var i = 0; i < vData.length; i++) {
        if (vData[i] > maxV) maxV = vData[i];
      }

      // 適応的しきい値の計算
      // 鮮やかな色がある場合は高めのしきい値(最大60)で背景のノイズを除去
      // 全体的に低彩度（白い壁や灰色）の場合はしきい値を下げて(最低15)、わずかな色味を捉える
      final thS = (maxS * 0.25).clamp(15.0, 60.0);
      
      // 暗い画像の場合は低めのしきい値(最低15)にして、暗い被写体を除去しすぎないようにする
      final thV = (maxV * 0.20).clamp(15.0, 45.0);

      maskS = cv.Mat.empty();
      maskV = cv.Mat.empty();
      cv.threshold(S, thS.toDouble(), 255.0, cv.THRESH_BINARY, dst: maskS);
      cv.threshold(V, thV.toDouble(), 255.0, cv.THRESH_BINARY, dst: maskV);
      
      mask = cv.bitwiseAND(maskS, maskV);

      // 1. Hue Hist (180 bins)
      histH = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([0]),
        mask,
        cv.VecI32.fromList([180]),
        cv.VecF32.fromList([0, 180]),
      );
      histHNorm = cv.Mat.empty();
      cv.normalize(histH, histHNorm, alpha: 1.0, beta: 0.0, normType: cv.NORM_L1);

      // 2. Saturation Hist (256 bins)
      histS = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([1]),
        mask,
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      histSNorm = cv.Mat.empty();
      cv.normalize(histS, histSNorm, alpha: 1.0, beta: 0.0, normType: cv.NORM_L1);

      // 3. Value Hist (256 bins)
      histV = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([2]),
        mask,
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      histVNorm = cv.Mat.empty();
      cv.normalize(histV, histVNorm, alpha: 1.0, beta: 0.0, normType: cv.NORM_L1);

      for (final c in channels) {
        c.dispose();
      }

      final hData = histHNorm.data;
      final sHistData = histSNorm.data;
      final vHistData = histVNorm.data;

      if (hData.isEmpty || sHistData.isEmpty || vHistData.isEmpty) return null;

      final hFloat = Float32List.sublistView(hData);
      final sFloat = Float32List.sublistView(sHistData);
      final vFloat = Float32List.sublistView(vHistData);

      // Combine H, S, V histograms (180 + 256 + 256 = 692 elements)
      final combined = Float32List(180 + 256 + 256);
      combined.setRange(0, 180, hFloat);
      combined.setRange(180, 180 + 256, sFloat);
      combined.setRange(180 + 256, 180 + 256 + 256, vFloat);

      return combined;
    } catch (e, s) {
      print('Error in _calcHueHistogramFromMat: $e\n$s');
      return null;
    } finally {
      centerMat?.dispose();
      hsv?.dispose();
      maskS?.dispose();
      maskV?.dispose();
      mask?.dispose();
      histH?.dispose();
      histHNorm?.dispose();
      histS?.dispose();
      histSNorm?.dispose();
      histV?.dispose();
      histVNorm?.dispose();
    }
  }

  static _PortraitResult _portraitAnalyzeWindowsFromMat(
    cv.Mat mat, {
    required cv.CascadeClassifier faceCascade,
    required cv.CascadeClassifier eyeCascade,
  }) {
    cv.Mat? gray;
    try {
      if (mat.isEmpty) return const _PortraitResult.none();
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);

      final faces = faceCascade.detectMultiScale(
        gray,
        scaleFactor: 1.1,
        minNeighbors: 3,
        minSize: (48, 48),
      );
      if (faces.isEmpty) return const _PortraitResult.none();

      // Find largest area to determine threshold
      double maxArea = 0;
      for (final r in faces) {
        final area = (r.width * r.height).toDouble();
        if (area > maxArea) {
          maxArea = area;
        }
      }

      // Keep only faces that are at least 25% of the largest face area
      final mainFaces = faces.where((r) {
        final area = r.width * r.height;
        return area >= (maxArea * 0.25);
      }).toList();

      // Primary face is the largest one
      cv.Rect primaryFace = mainFaces.first;
      var primaryArea = primaryFace.width * primaryFace.height;
      for (final r in mainFaces.skip(1)) {
        final area = r.width * r.height;
        if (area > primaryArea) {
          primaryFace = r;
          primaryArea = area;
        }
      }

      double totalFaceSharpness = 0.0;
      double totalEyeSharpness = 0.0;
      int eyeSharpnessCount = 0;
      var anyEyesClosed = false;
      var allBothEyesDetected = true;

      for (final faceRect in mainFaces) {
        final fSharp = _calcLaplacianVarianceInRoi(mat, faceRect);
        totalFaceSharpness += fSharp;

        final faceGray = gray.region(faceRect);
        var faceEyesClosed = false;
        var faceBothEyesDetected = false;

        try {
          if (!faceGray.isEmpty) {
            final eyes = eyeCascade.detectMultiScale(
              faceGray,
              scaleFactor: 1.1,
              minNeighbors: 3,
              minSize: (16, 16),
            );
            faceBothEyesDetected = eyes.length >= 2;

            // Windows environment eye close detection threshold heuristics
            faceEyesClosed = eyes.isEmpty && faceRect.width >= 120;

            if (eyes.isNotEmpty) {
              for (final eyeRect in eyes) {
                final absEyeRect = cv.Rect(
                  faceRect.x + eyeRect.x,
                  faceRect.y + eyeRect.y,
                  eyeRect.width,
                  eyeRect.height,
                );
                final v = _calcLaplacianVarianceInRoi(mat, absEyeRect);
                if (v > 0) {
                  totalEyeSharpness += v;
                  eyeSharpnessCount++;
                }
              }
            }
          } else {
            faceBothEyesDetected = false;
          }
        } finally {
          faceGray.dispose();
        }

        if (faceEyesClosed) {
          anyEyesClosed = true;
        }
        if (!faceBothEyesDetected) {
          allBothEyesDetected = false;
        }
      }

      final avgFaceSharpness = totalFaceSharpness / mainFaces.length;
      var avgEyeSharpness = -1.0;
      if (eyeSharpnessCount > 0) {
        final avgV = totalEyeSharpness / eyeSharpnessCount;
        avgEyeSharpness = (avgV / 1000.0).clamp(0.0, 1.0);
      }

      return _PortraitResult(
        hasFace: true,
        faceX: primaryFace.x,
        faceY: primaryFace.y,
        faceW: primaryFace.width,
        faceH: primaryFace.height,
        faceSharpness: avgFaceSharpness,
        eyeOpenAvg: -1,
        eyesClosed: anyEyesClosed,
        bothEyesDetected: allBothEyesDetected,
        eyeSharpness: avgEyeSharpness,
      );
    } catch (e, s) {
      print('Error in _portraitAnalyzeWindowsFromMat: $e\n$s');
      return const _PortraitResult.none();
    } finally {
      gray?.dispose();
    }
  }

  static double _calcLaplacianVarianceInRoi(cv.Mat bgr, cv.Rect roi) {
    cv.Mat? sub;
    cv.Mat? gray;
    cv.Mat? lap;
    try {
      if (bgr.isEmpty) return 0;
      final x1 = roi.x.clamp(0, bgr.cols - 1);
      final y1 = roi.y.clamp(0, bgr.rows - 1);
      final x2 = (roi.x + roi.width).clamp(0, bgr.cols);
      final y2 = (roi.y + roi.height).clamp(0, bgr.rows);
      final w = x2 - x1;
      final h = y2 - y1;

      if (w <= 0 || h <= 0) return 0;
      final safe = cv.Rect(x1, y1, w, h);
      sub = bgr.region(safe);
      if (sub.isEmpty) return 0;

      gray = cv.cvtColor(sub, cv.COLOR_BGR2GRAY);
      lap = cv.laplacian(gray, cv.MatType.CV_64F);
      final (_, stddev) = cv.meanStdDev(lap);
      final v = stddev.val1 * stddev.val1;
      return v.isFinite ? v : 0;
    } catch (e, s) {
      print('Error in _calcLaplacianVarianceInRoi: $e\n$s');
      return 0;
    } finally {
      sub?.dispose();
      gray?.dispose();
      lap?.dispose();
    }
  }

  static double _fallbackLaplacianVariance(
    Uint8List bytes, {
    int? x,
    int? y,
    int? w,
    int? h,
  }) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return 0;

      img.Image work = decoded;
      if (x != null && y != null && w != null && h != null) {
        final rx = x.clamp(0, decoded.width - 1);
        final ry = y.clamp(0, decoded.height - 1);
        final rw = w.clamp(1, decoded.width - rx);
        final rh = h.clamp(1, decoded.height - ry);
        // image:^3.3.0 uses positional args.
        work = img.copyCrop(decoded, rx, ry, rw, rh);
      }

      const maxEdge = 256;
      if (work.width > maxEdge || work.height > maxEdge) {
        final scale =
            maxEdge / (work.width > work.height ? work.width : work.height);
        work = img.copyResize(
          work,
          width: (work.width * scale).round(),
          height: (work.height * scale).round(),
        );
      }
      if (work.width < 3 || work.height < 3) return 0;

      int grayAt(int xx, int yy) {
        final p = work.getPixel(xx, yy);
        final r = img.getRed(p);
        final g = img.getGreen(p);
        final b = img.getBlue(p);
        return ((0.299 * r) + (0.587 * g) + (0.114 * b)).round();
      }

      double mean = 0;
      double meanSq = 0;
      var n = 0;
      for (var yy = 1; yy < work.height - 1; yy++) {
        for (var xx = 1; xx < work.width - 1; xx++) {
          final c = grayAt(xx, yy);
          final v =
              grayAt(xx, yy - 1) +
              grayAt(xx, yy + 1) +
              grayAt(xx - 1, yy) +
              grayAt(xx + 1, yy) -
              (4 * c);
          final dv = v.toDouble();
          n++;
          mean += dv;
          meanSq += dv * dv;
        }
      }
      if (n == 0) return 0;
      mean /= n;
      meanSq /= n;
      final variance = (meanSq - (mean * mean));
      return variance.isFinite ? variance.abs() : 0;
    } catch (e, s) {
      print('Error in _fallbackLaplacianVariance: $e\n$s');
      return 0;
    }
  }

  static Future<_PortraitResult> _portraitAnalyzeAndroid(
    Uint8List bytes, {
    required FaceDetector faceDetector,
    required Directory tmpDir,
  }) async {
    cv.Mat? mat;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return const _PortraitResult.none();
      }

      final fp = p.join(
        tmpDir.path,
        'bestshot_portrait_${bytes.length}_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      final file = File(fp);
      await file.writeAsBytes(bytes, flush: true);

      final input = InputImage.fromFilePath(fp);
      final faces = await faceDetector.processImage(input);

      // Clean up the temp file immediately.
      if (await file.exists()) {
        await file.delete();
      }

      if (faces.isEmpty) {
        return const _PortraitResult.none();
      }

      // Find largest area to determine threshold
      double maxArea = 0;
      for (final f in faces) {
        final area = (f.boundingBox.width * f.boundingBox.height).toDouble();
        if (area > maxArea) {
          maxArea = area;
        }
      }

      // Keep only faces that are at least 25% of the largest face area
      final mainFaces = faces.where((f) {
        final area = f.boundingBox.width * f.boundingBox.height;
        return area >= (maxArea * 0.25);
      }).toList();

      // Primary face is the largest one
      Face primaryFace = mainFaces.first;
      var primaryArea = primaryFace.boundingBox.width * primaryFace.boundingBox.height;
      for (final f in mainFaces.skip(1)) {
        final area = f.boundingBox.width * f.boundingBox.height;
        if (area > primaryArea) {
          primaryFace = f;
          primaryArea = area;
        }
      }

      double totalFaceSharpness = 0.0;
      double totalEyeSharpness = 0.0;
      int eyeSharpnessCount = 0;
      double minEyeOpen = 1.0;
      bool anyEyesClosed = false;
      bool allBothEyesDetected = true;
      bool anyBothEyesDetected = false;

      for (final face in mainFaces) {
        final bb = face.boundingBox;
        final rx = bb.left.round();
        final ry = bb.top.round();
        final rw = bb.width.round();
        final rh = bb.height.round();

        // Sharpness calculation in face ROI
        final roi = cv.Rect(rx, ry, rw, rh);
        var fSharp = _calcLaplacianVarianceInRoi(mat, roi);
        if (fSharp <= 0) {
          fSharp = _fallbackLaplacianVariance(
            bytes,
            x: rx,
            y: ry,
            w: rw,
            h: rh,
          );
        }
        totalFaceSharpness += fSharp;

        // Eye open probability (0.0 to 1.0)
        final le = face.leftEyeOpenProbability;
        final re = face.rightEyeOpenProbability;
        var faceEyeAvg = -1.0;
        var faceEyesClosed = false;

        if (le != null && re != null) {
          faceEyeAvg = (le + re) / 2.0;
          anyBothEyesDetected = true;
          faceEyesClosed = (faceEyeAvg < 0.4) || (le < 0.2) || (re < 0.2);
        } else if (le != null) {
          faceEyeAvg = le;
          faceEyesClosed = le < 0.4;
          allBothEyesDetected = false;
        } else if (re != null) {
          faceEyeAvg = re;
          faceEyesClosed = re < 0.4;
          allBothEyesDetected = false;
        } else {
          allBothEyesDetected = false;
        }

        if (faceEyeAvg >= 0) {
          if (faceEyeAvg < minEyeOpen) {
            minEyeOpen = faceEyeAvg;
          }
          if (faceEyesClosed) {
            anyEyesClosed = true;
          }
        }

        // Eye Sharpness (using landmarks)
        final leftLandmark = face.landmarks[FaceLandmarkType.leftEye];
        final rightLandmark = face.landmarks[FaceLandmarkType.rightEye];

        if (leftLandmark != null) {
          final ex = leftLandmark.position.x;
          final ey = leftLandmark.position.y;
          final ew = (rw * 0.15).round(); // Eye ROI size approx 15% of face width
          final eroi = cv.Rect(
            (ex - ew / 2).round(),
            (ey - ew / 2).round(),
            ew,
            ew,
          );
          final v = _calcLaplacianVarianceInRoi(mat, eroi);
          if (v > 0) {
            totalEyeSharpness += v;
            eyeSharpnessCount++;
          }
        }
        if (rightLandmark != null) {
          final ex = rightLandmark.position.x;
          final ey = rightLandmark.position.y;
          final ew = (rw * 0.15).round();
          final eroi = cv.Rect(
            (ex - ew / 2).round(),
            (ey - ew / 2).round(),
            ew,
            ew,
          );
          final v = _calcLaplacianVarianceInRoi(mat, eroi);
          if (v > 0) {
            totalEyeSharpness += v;
            eyeSharpnessCount++;
          }
        }
      }

      final avgFaceSharpness = totalFaceSharpness / mainFaces.length;
      var avgEyeSharpness = -1.0;
      if (eyeSharpnessCount > 0) {
        final avgV = totalEyeSharpness / eyeSharpnessCount;
        avgEyeSharpness = (avgV / 1000.0).clamp(0.0, 1.0);
      }

      final finalEyeOpenAvg = (minEyeOpen == 1.0 && !anyBothEyesDetected) ? -1.0 : minEyeOpen;

      final pBb = primaryFace.boundingBox;
      return _PortraitResult(
        hasFace: true,
        faceX: pBb.left.round(),
        faceY: pBb.top.round(),
        faceW: pBb.width.round(),
        faceH: pBb.height.round(),
        faceSharpness: avgFaceSharpness,
        eyeOpenAvg: finalEyeOpenAvg,
        eyesClosed: anyEyesClosed,
        bothEyesDetected: allBothEyesDetected,
        eyeSharpness: avgEyeSharpness,
      );
    } catch (e) {
      return const _PortraitResult.none();
    } finally {
      mat?.dispose();
    }
  }

  static Future<String> _ensureAssetFile({
    required String assetPath,
    required String outPath,
  }) async {
    final f = File(outPath);
    if (await f.exists()) return outPath;
    final data = await rootBundle.load(assetPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return outPath;
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
  _TransferableInput({required this.key, this.data, this.filePath});

  final String key;
  final TransferableTypedData? data;
  final String? filePath;
}

class _OrbDesc {
  const _OrbDesc({required this.rows, required this.cols, required this.bytes});
  _OrbDesc.empty() : rows = 0, cols = 0, bytes = Uint8List(0);
  final int rows;
  final int cols;
  final Uint8List bytes;
}

class _PortraitResult {
  const _PortraitResult({
    required this.hasFace,
    required this.faceX,
    required this.faceY,
    required this.faceW,
    required this.faceH,
    required this.faceSharpness,
    required this.eyeOpenAvg,
    required this.eyesClosed,
    required this.bothEyesDetected,
    required this.eyeSharpness,
  });

  const _PortraitResult.none()
    : hasFace = false,
      faceX = 0,
      faceY = 0,
      faceW = 0,
      faceH = 0,
      faceSharpness = 0,
      eyeOpenAvg = -1,
      eyesClosed = false,
      bothEyesDetected = false,
      eyeSharpness = -1;

  final bool hasFace;
  final int faceX;
  final int faceY;
  final int faceW;
  final int faceH;
  final double faceSharpness;
  final double eyeOpenAvg;
  final bool eyesClosed;
  final bool bothEyesDetected;
  final double eyeSharpness;
}
