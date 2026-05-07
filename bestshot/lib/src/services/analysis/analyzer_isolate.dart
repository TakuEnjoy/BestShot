import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
      if (!await cascadeDir.exists()) {
        await cascadeDir.create(recursive: true);
      }
      final facePath = await _ensureAssetFile(
        assetPath: 'assets/cascades/haarcascade_frontalface_default.xml',
        outPath: p.join(cascadeDir.path, 'haarcascade_frontalface_default.xml'),
      );
      final eyePath = await _ensureAssetFile(
        assetPath: 'assets/cascades/haarcascade_eye.xml',
        outPath: p.join(cascadeDir.path, 'haarcascade_eye.xml'),
      );
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
    Uint8List bytes;
    if (filePath != null) {
      bytes = await File(filePath).readAsBytes();
    } else {
      bytes = displayBytes ?? Uint8List(0);
    }

    if (bytes.isEmpty) {
      return AnalyzeOutput(
        key: key,
        pHashHex: '0000000000000000',
        sharpness: 0,
        exposureScore: 0,
        orbRows: 0,
        orbCols: 0,
        orbBytes: Uint8List(0),
        histogram: Uint8List(256),
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
      );
    }

    final pHashHex = _calcEqualizedPHashHex(bytes);
    final fullSharpness = _calcLaplacianVariance(bytes);
    final (exposure, histogram) = _calcExposureAndHistogram(bytes);
    final orb = _calcOrbDescriptors(bytes);

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
          bytes,
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
        final r = _portraitAnalyzeWindows(
          bytes,
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
        // 瞳のピントを重視
        sharpnessForScore = (sharpnessForScore * 0.4) + (eyeSharpness * 0.6);
      }
      if (eyesClosed) {
        sharpnessForScore *= 0.2; // 大幅減点
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
    );
  }

  static String _calcEqualizedPHashHex(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return '0000000000000000';

      final resized = img.copyResize(decoded, width: 32, height: 32);

      // Build grayscale buffer.
      final gray = Uint8List(32 * 32);
      var idx = 0;
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          final px = resized.getPixel(x, y);
          final r = img.getRed(px);
          final g = img.getGreen(px);
          final b = img.getBlue(px);
          // luminance approx
          final v = ((0.299 * r) + (0.587 * g) + (0.114 * b)).round().clamp(
            0,
            255,
          );
          gray[idx++] = v;
        }
      }

      // Histogram equalization (on grayscale).
      final hist = List<int>.filled(256, 0);
      for (final v in gray) {
        hist[v]++;
      }
      final cdf = List<int>.filled(256, 0);
      var c = 0;
      for (var i = 0; i < 256; i++) {
        c += hist[i];
        cdf[i] = c;
      }
      final total = gray.length;
      var cdfMin = 0;
      for (var i = 0; i < 256; i++) {
        if (cdf[i] != 0) {
          cdfMin = cdf[i];
          break;
        }
      }
      final lut = Uint8List(256);
      for (var i = 0; i < 256; i++) {
        final num = (cdf[i] - cdfMin);
        final den = (total - cdfMin);
        final mapped = den <= 0 ? 0 : ((num * 255) / den).round();
        lut[i] = mapped.clamp(0, 255);
      }

      final pixels = <ic.Pixel>[];
      for (final v in gray) {
        final e = lut[v];
        pixels.add(ic.Pixel(e, e, e, 255));
      }
      // calcPhash mutates list internally; keep it dynamic to avoid runtime type errors.
      final dynamicPixelList = <dynamic>[...pixels];
      final hex = ic.PerceptualHash().calcPhash(dynamicPixelList);
      return hex.padLeft(16, '0');
    } catch (_) {
      return '0000000000000000';
    }
  }

  static double _calcLaplacianVariance(Uint8List bytes) {
    cv.Mat? mat;
    cv.Mat? gray;
    cv.Mat? lap;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return _fallbackLaplacianVariance(bytes);
      }
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
      lap = cv.laplacian(gray, cv.MatType.CV_64F);
      final (_, stddev) = cv.meanStdDev(lap);
      final v = stddev.val1 * stddev.val1;
      final out = (v.isFinite ? v : 0).toDouble();
      // If OpenCV path fails (often returns 0), keep a pure-Dart fallback.
      return out > 0 ? out : _fallbackLaplacianVariance(bytes);
    } catch (_) {
      return _fallbackLaplacianVariance(bytes);
    } finally {
      mat?.dispose();
      gray?.dispose();
      lap?.dispose();
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
    } catch (_) {
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
    } catch (_) {
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

      // Find the "best" face (largest area).
      Face best = faces.first;
      var bestArea = best.boundingBox.width * best.boundingBox.height;
      for (final f in faces.skip(1)) {
        final bb = f.boundingBox;
        final area = bb.width * bb.height;
        if (area > bestArea) {
          best = f;
          bestArea = area;
        }
      }

      final bb = best.boundingBox;
      // Coordinates can be negative if face is partially out of frame.
      final rx = bb.left.round();
      final ry = bb.top.round();
      final rw = bb.width.round();
      final rh = bb.height.round();

      // Sharpness calculation in face ROI.
      final roi = cv.Rect(rx, ry, rw, rh);
      var faceSharpness = _calcLaplacianVarianceInRoi(mat, roi);
      if (faceSharpness <= 0) {
        faceSharpness = _fallbackLaplacianVariance(
          bytes,
          x: rx,
          y: ry,
          w: rw,
          h: rh,
        );
      }

      // Eye open probability (0.0 to 1.0).
      final le = best.leftEyeOpenProbability;
      final re = best.rightEyeOpenProbability;
      var eyeAvg = -1.0;
      var eyesClosed = false;
      var bothEyesDetected = false;

      if (le != null && re != null) {
        eyeAvg = (le + re) / 2.0;
        bothEyesDetected = true;
        // Threshold for "eyes closed". 0.4 is often a good balance.
        // If average is low, or either eye is very closed.
        eyesClosed = (eyeAvg < 0.4) || (le < 0.2) || (re < 0.2);
      } else if (le != null) {
        eyeAvg = le;
        eyesClosed = le < 0.4;
      } else if (re != null) {
        eyeAvg = re;
        eyesClosed = re < 0.4;
      }

      // Eye Sharpness (using landmarks)
      var eyeSharpness = -1.0;
      final leftLandmark = best.landmarks[FaceLandmarkType.leftEye];
      final rightLandmark = best.landmarks[FaceLandmarkType.rightEye];

      final eyeVariances = <double>[];
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
        if (v > 0) eyeVariances.add(v);
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
        if (v > 0) eyeVariances.add(v);
      }

      if (eyeVariances.isNotEmpty) {
        final avgV = eyeVariances.reduce((a, b) => a + b) / eyeVariances.length;
        // Normalize 0..1 using a sigmoid-like function or simple cap.
        // Typical "sharp" variance can be 500-2000+.
        eyeSharpness = (avgV / 1000.0).clamp(0.0, 1.0);
      }

      return _PortraitResult(
        hasFace: true,
        faceX: rx,
        faceY: ry,
        faceW: rw,
        faceH: rh,
        faceSharpness: faceSharpness,
        eyeOpenAvg: eyeAvg,
        eyesClosed: eyesClosed,
        bothEyesDetected: bothEyesDetected,
        eyeSharpness: eyeSharpness,
      );
    } catch (e) {
      // In case of error, we can at least return something if we have a mat.
      return const _PortraitResult.none();
    } finally {
      mat?.dispose();
    }
  }

  static _PortraitResult _portraitAnalyzeWindows(
    Uint8List bytes, {
    required cv.CascadeClassifier faceCascade,
    required cv.CascadeClassifier eyeCascade,
  }) {
    cv.Mat? mat;
    cv.Mat? gray;
    cv.Mat? faceGray;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) return const _PortraitResult.none();
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);

      final faces = faceCascade.detectMultiScale(
        gray,
        scaleFactor: 1.1,
        minNeighbors: 3,
        minSize: (48, 48),
      );
      if (faces.isEmpty) return const _PortraitResult.none();

      cv.Rect best = faces[0];
      var bestArea = best.width * best.height;
      for (final r in faces) {
        final area = r.width * r.height;
        if (area > bestArea) {
          best = r;
          bestArea = area;
        }
      }

      final faceSharpness = _calcLaplacianVarianceInRoi(mat, best);

      faceGray = gray.region(best);
      var eyesClosed = false;
      var bothEyesDetected = false;
      if (!faceGray.isEmpty) {
        final eyes = eyeCascade.detectMultiScale(
          faceGray,
          scaleFactor: 1.1,
          minNeighbors: 3,
          minSize: (16, 16),
        );
        bothEyesDetected = eyes.length >= 2;
        eyesClosed = eyes.isEmpty;
      }

      return _PortraitResult(
        hasFace: true,
        faceX: best.x,
        faceY: best.y,
        faceW: best.width,
        faceH: best.height,
        faceSharpness: faceSharpness,
        eyeOpenAvg: -1,
        eyesClosed: eyesClosed,
        bothEyesDetected: bothEyesDetected,
        eyeSharpness: -1,
      );
    } catch (_) {
      return const _PortraitResult.none();
    } finally {
      mat?.dispose();
      gray?.dispose();
      faceGray?.dispose();
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

  static (double, Uint8List) _calcExposureAndHistogram(Uint8List bytes) {
    cv.Mat? mat;
    cv.Mat? gray;
    cv.Mat? hist;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) return (0.0, Uint8List(256));
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);

      // Histogram (256 bins)
      hist = cv.calcHist(
        cv.VecMat.fromList([gray]),
        cv.VecI32.fromList([0]),
        cv.Mat.empty(),
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      final data = hist.data;
      if (data.isEmpty) return (0.0, Uint8List(256));

      // Normalize histogram for display/storage
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

      // clip ratio in shadows (0..5) and highlights (250..255)
      double clipLow = 0;
      for (var i = 0; i <= 5; i++) {
        clipLow += data[i];
      }
      double clipHigh = 0;
      for (var i = 250; i < 256; i++) {
        clipHigh += data[i];
      }
      final clip = (clipLow + clipHigh) / sum;

      // mean brightness penalty
      final (mean, _) = cv.meanStdDev(gray);
      final meanVal = mean.val1;
      final meanPenalty = (meanVal - 127.0).abs() / 127.0; // 0..~1

      final score = (1.0 - clip) * (1.0 - (meanPenalty * 0.35));
      return (score.clamp(0.0, 1.0), normHist);
    } catch (_) {
      return (0.0, Uint8List(256));
    } finally {
      mat?.dispose();
      gray?.dispose();
      hist?.dispose();
    }
  }

  static _OrbDesc _calcOrbDescriptors(Uint8List bytes) {
    cv.Mat? mat;
    cv.Mat? small;
    cv.Mat? gray;
    cv.Mat? eq;
    cv.Mat? desc;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) return _OrbDesc.empty();

      // Smaller image for faster ORB (keep aspect by scaling via fx/fy)
      small = cv.resize(mat, (640, 640));
      gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      eq = cv.equalizeHist(gray);

      final orb = cv.ORB.create(nFeatures: 600, scaleFactor: 1.2, nLevels: 8);
      final result = orb.detectAndCompute(eq, cv.Mat.empty());
      desc = result.$2;
      // Keep at most first 256 descriptors to limit CPU in Dart matcher.
      if (desc.isEmpty) return _OrbDesc.empty();
      final rows = desc.rows > 256 ? 256 : desc.rows;
      final cols = desc.cols;
      final elemSize = desc.elemSize;
      final bytesLen = rows * cols * elemSize;
      final all = desc.data;
      if (all.length < bytesLen) return _OrbDesc.empty();
      final sliced = Uint8List.fromList(all.sublist(0, bytesLen));
      return _OrbDesc(rows: rows, cols: cols, bytes: sliced);
    } catch (_) {
      return _OrbDesc.empty();
    } finally {
      mat?.dispose();
      small?.dispose();
      gray?.dispose();
      eq?.dispose();
      desc?.dispose();
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
