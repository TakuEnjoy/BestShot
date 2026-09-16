import 'dart:developer' as developer;
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'analysis_types.dart';
import '../../utils/jpeg_utils.dart';

class AnalyzerIsolate {
  static Future<List<AnalyzeOutput>> analyzeAll(
    List<AnalyzeInput> inputs, {
    DetectionMode mode = DetectionMode.standard,
    RootIsolateToken? rootIsolateToken,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    int? overrideWorkerCount,
  }) async {
    if (inputs.isEmpty) return [];

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

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final processorCount = Platform.numberOfProcessors;
    final maxWorkers = isMobile ? 3 : 6;
    final calculatedWorkerCount = (processorCount ~/ 2).clamp(1, maxWorkers);
    final workerCount = overrideWorkerCount ?? calculatedWorkerCount;
    final actualWorkerCount = workerCount > inputs.length
        ? inputs.length
        : workerCount;

    final receivePort = ReceivePort();
    final errorPort = ReceivePort();

    final List<Isolate> isolates = [];
    final results = <AnalyzeOutput>[];
    final completer = Completer<List<AnalyzeOutput>>();

    int nextInputIndex = 0;
    int doneCount = 0;
    final workerSendPorts = <int, SendPort>{};
    var finishedWorkers = 0;

    late StreamSubscription sub;
    late StreamSubscription errSub;
    Timer? cancelTimer;

    void assignNextTask(int workerId, SendPort workerSendPort) {
      if (nextInputIndex < inputs.length) {
        final input = inputs[nextInputIndex++];
        final transferable =
            (input.displayBytes != null && input.filePath == null)
            ? _TransferableInput(
                key: input.key,
                data: TransferableTypedData.fromList([input.displayBytes!]),
              )
            : _TransferableInput(key: input.key, filePath: input.filePath);

        workerSendPort.send(_MainTaskMessage(input: transferable));
      } else {
        workerSendPort.send(_MainShutdownMessage());
      }
    }

    try {
      for (var id = 0; id < actualWorkerCount; id++) {
        final isolate = await Isolate.spawn<_AnalyzerInitMessage>(
          _entry,
          _AnalyzerInitMessage(
            mainSendPort: receivePort.sendPort,
            workerId: id,
            mode: mode,
            rootIsolateToken: rootIsolateToken,
          ),
          onError: errorPort.sendPort,
        );
        isolates.add(isolate);
      }
    } catch (e) {
      for (final iso in isolates) {
        iso.kill(priority: Isolate.immediate);
      }
      rethrow;
    }

    void shutdownWorkers() {
      for (final sp in workerSendPorts.values) {
        try {
          sp.send(const _MainShutdownMessage());
        } catch (_) {}
      }
    }

    sub = receivePort.listen((message) {
      if (isCancelled?.call() == true) {
        shutdownWorkers();
        if (!completer.isCompleted) {
          completer.completeError(Exception('キャンセルされました'));
        }
        return;
      }
      if (message is _WorkerMessage) {
        if (message is _WorkerInitMessage) {
          final workerId = message.workerId;
          final sp = message.sendPort;
          workerSendPorts[workerId] = sp;
          assignNextTask(workerId, sp);
        } else if (message is _WorkerResultMessage) {
          final workerId = message.workerId;
          final out = message.output;
          results.add(out);
          doneCount++;
          onProgress?.call(doneCount, inputs.length);

          if (workerSendPorts.containsKey(workerId)) {
            assignNextTask(workerId, workerSendPorts[workerId]!);
          }
        } else if (message is _WorkerErrorMessage) {
          shutdownWorkers();
          if (!completer.isCompleted) {
            final target = message.filePath != null
                ? p.basename(message.filePath!)
                : (message.failedKey ?? 'Worker ${message.workerId}');
            completer.completeError(
              AnalysisException(
                '写真解析中にエラーが発生しました ($target): ${message.errorMessage}',
                itemKey: message.failedKey,
                filePath: message.filePath,
                cause: message.errorMessage,
              ),
            );
          }
        } else if (message is _WorkerDoneMessage) {
          finishedWorkers++;
          if (finishedWorkers >= actualWorkerCount) {
            if (!completer.isCompleted) completer.complete(results);
          }
        }
      }
    });

    errSub = errorPort.listen((e) {
      if (isCancelled?.call() == true) return;
      shutdownWorkers();
      if (!completer.isCompleted) {
        if (e is List && e.isNotEmpty) {
          completer.completeError(Exception(e.first.toString()));
        } else {
          completer.completeError(e is Exception ? e : Exception(e.toString()));
        }
      }
    });

    if (isCancelled != null) {
      cancelTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        if (isCancelled()) {
          timer.cancel();
          shutdownWorkers();
          if (!completer.isCompleted) {
            completer.completeError(Exception('キャンセルされました'));
          }
        }
      });
    }

    try {
      return await completer.future;
    } finally {
      cancelTimer?.cancel();
      shutdownWorkers();

      // ワーカーの正常終了（リソース解放）を短時間待機
      if (finishedWorkers < actualWorkerCount) {
        final deadline = DateTime.now().add(const Duration(milliseconds: 300));
        while (finishedWorkers < actualWorkerCount && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }

      await sub.cancel();
      await errSub.cancel();
      receivePort.close();
      errorPort.close();
      for (final iso in isolates) {
        iso.kill(priority: Isolate.immediate);
      }
    }
  }

  static void _entry(_AnalyzerInitMessage message) {
    // Isolate.spawn の entrypoint は「void Function(T)」である必要があるため、
    // async を直接渡さずに内部の async 処理へ委譲する。
    _entryAsync(message).catchError((e, s) {
      developer.log('Analyzer _entryAsync fatal error: $e\n$s');
      try {
        message.mainSendPort.send(
          _WorkerErrorMessage(
            workerId: message.workerId,
            errorMessage: 'Isolate初期化失敗: $e',
            stackTrace: s.toString(),
          ),
        );
      } catch (_) {}
    });
  }

  static Future<void> _entryAsync(_AnalyzerInitMessage message) async {
    if (message.rootIsolateToken != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(
        message.rootIsolateToken!,
      );
    }

    final workerReceivePort = ReceivePort();
    message.mainSendPort.send(
      _WorkerInitMessage(
        workerId: message.workerId,
        sendPort: workerReceivePort.sendPort,
      ),
    );

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
    }

    cv.ORB? orbDetector;
    try {
      if (message.mode == DetectionMode.portrait && isAndroid) {
        final baseTmp = await getTemporaryDirectory();
        tmpDir = Directory(p.join(baseTmp.path, 'bestshot_isolate_${message.workerId}'));
        if (!await tmpDir.exists()) {
          await tmpDir.create(recursive: true);
        }
      }

      if (message.mode == DetectionMode.portrait && isWindows) {
        final support = await getApplicationSupportDirectory();
        final cascadeDir = Directory(p.join(support.path, 'cascades'));
        final facePath = p.join(
          cascadeDir.path,
          'haarcascade_frontalface_default.xml',
        );
        final eyePath = p.join(cascadeDir.path, 'haarcascade_eye.xml');
        faceCascade = cv.CascadeClassifier.fromFile(facePath);
        eyeCascade = cv.CascadeClassifier.fromFile(eyePath);
      }

      orbDetector = cv.ORB.create(
        nFeatures: 800,
        scaleFactor: 1.2,
        nLevels: 8,
        edgeThreshold: 15,
        fastThreshold: 10,
      );
      await for (final msg in workerReceivePort) {
        if (msg is _MainShutdownMessage) {
          break;
        } else if (msg is _MainTaskMessage) {
          final input = msg.input;
          try {
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
              orbDetector: orbDetector,
            );
            message.mainSendPort.send(
              _WorkerResultMessage(workerId: message.workerId, output: out),
            );
          } catch (e, s) {
            developer.log('Error analyzing item ${input.key} (${input.filePath}): $e\n$s');
            message.mainSendPort.send(
              _WorkerErrorMessage(
                workerId: message.workerId,
                failedKey: input.key,
                filePath: input.filePath,
                errorMessage: e.toString(),
                stackTrace: s.toString(),
              ),
            );
            break;
          }
        }
      }
    } finally {
      if (tmpDir != null && await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
      orbDetector?.dispose();
      await faceDetector?.close();
      faceCascade?.dispose();
      eyeCascade?.dispose();
      workerReceivePort.close();
      message.mainSendPort.send(_WorkerDoneMessage(workerId: message.workerId));
    }
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
      orbKeypoints: Float32List(0),
      histogram: Uint8List(256),
      hueHistogram: null,
      hasFace: false,
      faceX: 0,
      faceY: 0,
      faceW: 0,
      faceH: 0,
      faceSharpness: 0,
      eyeOpenAvg: null,
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
    required cv.ORB orbDetector,
  }) async {
    const rawExts = <String>{
      '.dng',
      '.arw',
      '.nef',
      '.cr2',
      '.cr3',
      '.raf',
      '.rw2',
      '.orf',
    };

    Uint8List rawBytes;
    if (displayBytes != null && displayBytes.isNotEmpty) {
      // displayBytes（インポート時に抽出済みの高品質JPEG）を直接活用してディスク再読み込みをスキップ
      rawBytes = displayBytes;
    } else if (filePath != null) {
      final ext = p.extension(filePath).toLowerCase();
      final fileBytes = await File(filePath).readAsBytes();
      if (rawExts.contains(ext)) {
        final jpegBytes = JpegUtils.extractEmbeddedJpeg(fileBytes);
        rawBytes = jpegBytes != null ? Uint8List.fromList(jpegBytes) : fileBytes;
      } else {
        rawBytes = fileBytes;
      }
    } else {
      rawBytes = Uint8List(0);
    }

    if (rawBytes.isEmpty) {
      return _emptyOutput(key);
    }

    cv.Mat? mat;
    cv.Mat? work;

    try {
      mat = cv.imdecode(rawBytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return _emptyOutput(key);
      }

      // 8. 解析解像度の制限 (最大1920px以下にリサイズしてメモリとCPU負荷を削減)
      const maxAnalysisEdge = 1920;
      if (mat.cols > maxAnalysisEdge || mat.rows > maxAnalysisEdge) {
        final scale =
            maxAnalysisEdge / (mat.cols > mat.rows ? mat.cols : mat.rows);
        final resizedMat = cv.resize(mat, (
          (mat.cols * scale).round(),
          (mat.rows * scale).round(),
        ));
        mat.dispose();
        mat = resizedMat;
      }

      // Constants for resizing and JPEG quality
      const maxWorkEdge = 640;
      const jpegQuality = 90;

      // Resize for analysis (speed & accuracy)
      if (mat.cols > maxWorkEdge || mat.rows > maxWorkEdge) {
        final scale = maxWorkEdge / (mat.cols > mat.rows ? mat.cols : mat.rows);
        work = cv.resize(mat, (
          (mat.cols * scale).round(),
          (mat.rows * scale).round(),
        ));
      } else {
        work = mat;
      }
      final analysisWork = work;
      final pHashHex = _calcEqualizedPHashHexFromMat(analysisWork);
      final (fullSharpness, debugGridSharps) = _calcLaplacianVarianceFromMat(
        analysisWork,
        () {
          final res = cv.imencode('.jpg', analysisWork, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, jpegQuality]));
          return res.$1 ? res.$2 : null;
        },
      );
      final (exposure, histogram) = _calcExposureAndHistogramFromMat(analysisWork);
      final hueHistogram = _calcHueHistogramFromMat(analysisWork);
      final orb = _calcOrbDescriptorsFromMat(analysisWork, orbDetector);

      var hasFace = false;
      var faceX = 0;
      var faceY = 0;
      var faceW = 0;
      var faceH = 0;
      var faceSharpness = 0.0;
      double? eyeOpenAvg;
      var eyesClosed = false;
      var bothEyesDetected = false;
      var eyeSharpness = -1.0;

      var sharpnessForScore = fullSharpness;

      if (mode == DetectionMode.portrait) {
        if (Platform.isAndroid && faceDetector != null && tmpDir != null) {
          final r = await _portraitAnalyzeAndroid(
            rawBytes, // Use extracted JPEG for RAW files
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
            mat, // Resized to max 1920px
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
        orbKeypoints: orb.keypoints,
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
      developer.log('Isolate analysis error for key $key: $e\n$stack');
      return _emptyOutput(key);
    } finally {
      if (work != null && work != mat) {
        work.dispose();
      }
      mat?.dispose();
    }
  }

  static String _calcEqualizedPHashHexFromMat(cv.Mat mat) {
    cv.Mat? small;
    cv.Mat? gray;
    cv.Mat? eq;
    cv.Mat? fGray;
    cv.Mat? dctMat;
    cv.Mat? top8x8;
    try {
      small = cv.resize(mat, (32, 32));
      gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      eq = cv.equalizeHist(gray);
      fGray = eq.convertTo(cv.MatType.CV_32FC1);
      dctMat = cv.dct(fGray);
      top8x8 = dctMat.region(cv.Rect(0, 0, 8, 8));
      final cellVals = List<double>.filled(64, 0.0);
      final vals = <double>[];
      for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
          final v = top8x8.at<double>(r, c);
          cellVals[r * 8 + c] = v;
          if (r == 0 && c == 0) continue;
          vals.add(v);
        }
      }
      vals.sort();
      final median = vals[vals.length ~/ 2];
      BigInt hash = BigInt.zero;
      for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
          if (r == 0 && c == 0) continue;
          hash <<= 1;
          if (cellVals[r * 8 + c] > median) hash |= BigInt.one;
        }
      }
      return hash.toRadixString(16).padLeft(16, '0');
    } catch (e, s) {
      developer.log('Error in _calcEqualizedPHashHexFromMat: $e\n$s');
      return '0000000000000000';
    } finally {
      small?.dispose();
      gray?.dispose();
      eq?.dispose();
      fGray?.dispose();
      dctMat?.dispose();
      top8x8?.dispose();
    }
  }

  static (double, List<double>) _calcLaplacianVarianceFromMat(
    cv.Mat bgr,
    Uint8List? Function() getBytes,
  ) {
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
            developer.log('Error in cell _calcLaplacianVarianceFromMat: $e');
            variances.add(0.0);
          } finally {
            sub?.dispose();
            lap?.dispose();
          }
        }
      }

      // Find top 4 blocks to calculate subject focused average sharpness
      final sorted = List<double>.from(variances)
        ..sort((a, b) => b.compareTo(a));
      final topAvg = (sorted[0] + sorted[1] + sorted[2] + sorted[3]) / 4.0;

      return (topAvg.isFinite ? topAvg : 0.0, variances);
    } catch (e, s) {
      developer.log('Error in _calcLaplacianVarianceFromMat: $e\n$s');
      final bytes = getBytes();
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
      developer.log('Error in _calcExposureAndHistogramFromMat: $e\n$s');
      return (0.0, Uint8List(256));
    } finally {
      gray?.dispose();
      hist?.dispose();
    }
  }

  static _OrbDesc _calcOrbDescriptorsFromMat(cv.Mat mat, cv.ORB orbDetector) {
    cv.Mat? gray;
    cv.Mat? cl;
    cv.Mat? desc;
    cv.VecKeyPoint? kps;
    try {
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
      final clahe = cv.createCLAHE(clipLimit: 3.0, tileGridSize: (8, 8));
      cl = clahe.apply(gray);
      clahe.dispose();

      final emptyMat = cv.Mat.empty();
      final result = orbDetector.detectAndCompute(cl, emptyMat);
      desc = result.$2;
      kps = result.$1;

      emptyMat.dispose();

      if (desc.isEmpty) {
        return _OrbDesc.empty();
      }

      final rows = desc.rows > 800 ? 800 : desc.rows;
      final cols = desc.cols;
      final elemSize = desc.elemSize;
      final bytesLen = rows * cols * elemSize;
      final all = desc.data;

      if (all.length < bytesLen) {
        return _OrbDesc.empty();
      }

      final sliced = Uint8List.fromList(all.sublist(0, bytesLen));

      // Extract keypoints [x, y, x, y, ...] up to 'rows'
      final kpList = Float32List(rows * 2);
      for (var i = 0; i < rows; i++) {
        final kp = kps[i];
        kpList[i * 2] = kp.x;
        kpList[i * 2 + 1] = kp.y;
      }

      return _OrbDesc(rows: rows, cols: cols, bytes: sliced, keypoints: kpList);
    } catch (e, s) {
      developer.log('Error in _calcOrbDescriptorsFromMat: $e\n$s');
      return _OrbDesc.empty();
    } finally {
      kps?.dispose();
      gray?.dispose();
      cl?.dispose();
      desc?.dispose();
    }
  }

  static Float32List? _calcHueHistogramFromMat(cv.Mat bgr) {
    cv.Mat? hsv;
    cv.Mat? histH;
    cv.Mat? histS;
    cv.Mat? histV;
    cv.Mat? histHNorm;
    cv.Mat? histSNorm;
    cv.Mat? histVNorm;
    cv.Mat? emptyMask;
    try {
      if (bgr.isEmpty) return null;

      hsv = cv.cvtColor(bgr, cv.COLOR_BGR2HSV);
      emptyMask = cv.Mat.empty();

      histH = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([0]),
        emptyMask,
        cv.VecI32.fromList([180]),
        cv.VecF32.fromList([0, 180]),
      );
      histHNorm = cv.Mat.empty();
      cv.normalize(histH, histHNorm, alpha: 1.0, beta: 0.0, normType: cv.NORM_L1);

      histS = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([1]),
        emptyMask,
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      histSNorm = cv.Mat.empty();
      cv.normalize(histS, histSNorm, alpha: 1.0, beta: 0.0, normType: cv.NORM_L1);

      histV = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([2]),
        emptyMask,
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      histVNorm = cv.Mat.empty();
      cv.normalize(histV, histVNorm, alpha: 1.0, beta: 0.0, normType: cv.NORM_L1);

      final hData = histHNorm.data;
      final sHistData = histSNorm.data;
      final vHistData = histVNorm.data;

      if (hData.isEmpty || sHistData.isEmpty || vHistData.isEmpty) return null;

      final combined = Float32List(692);
      combined.setRange(0, 180, Float32List.sublistView(hData));
      combined.setRange(180, 436, Float32List.sublistView(sHistData));
      combined.setRange(436, 692, Float32List.sublistView(vHistData));

      return combined;
    } catch (e, s) {
      developer.log('Error in _calcHueHistogramFromMat: $e\n$s');
      return null;
    } finally {
      emptyMask?.dispose();
      hsv?.dispose();
      histH?.dispose();
      histS?.dispose();
      histV?.dispose();
      histHNorm?.dispose();
      histSNorm?.dispose();
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
        eyeOpenAvg: null,
        eyesClosed: anyEyesClosed,
        bothEyesDetected: allBothEyesDetected,
        eyeSharpness: avgEyeSharpness,
      );
    } catch (e, s) {
      developer.log('Error in _portraitAnalyzeWindowsFromMat: $e\n$s');
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
      developer.log('Error in _calcLaplacianVarianceInRoi: $e\n$s');
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
      developer.log('Error in _fallbackLaplacianVariance: $e\n$s');
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
      var primaryArea =
          primaryFace.boundingBox.width * primaryFace.boundingBox.height;
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
        double? faceEyeAvg;
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
          final ew = (rw * 0.15)
              .round(); // Eye ROI size approx 15% of face width
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

      final finalEyeOpenAvg = (minEyeOpen == 1.0 && !anyBothEyesDetected)
          ? null
          : minEyeOpen;

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

class _AnalyzerInitMessage {
  _AnalyzerInitMessage({
    required this.mainSendPort,
    required this.workerId,
    required this.mode,
    required this.rootIsolateToken,
  });

  final SendPort mainSendPort;
  final int workerId;
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
  const _OrbDesc({required this.rows, required this.cols, required this.bytes, required this.keypoints});
  _OrbDesc.empty() : rows = 0, cols = 0, bytes = Uint8List(0), keypoints = Float32List(0);
  final int rows;
  final int cols;
  final Uint8List bytes;
  final Float32List keypoints;
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
      eyeOpenAvg = null,
      eyesClosed = false,
      bothEyesDetected = false,
      eyeSharpness = -1;

  final bool hasFace;
  final int faceX;
  final int faceY;
  final int faceW;
  final int faceH;
  final double faceSharpness;
  final double? eyeOpenAvg;
  final bool eyesClosed;
  final bool bothEyesDetected;
  final double eyeSharpness;
}



sealed class _WorkerMessage {}

class _WorkerInitMessage extends _WorkerMessage {
  _WorkerInitMessage({required this.workerId, required this.sendPort});
  final int workerId;
  final SendPort sendPort;
}

class _WorkerResultMessage extends _WorkerMessage {
  _WorkerResultMessage({required this.workerId, required this.output});
  final int workerId;
  final AnalyzeOutput output;
}

class _WorkerDoneMessage extends _WorkerMessage {
  _WorkerDoneMessage({required this.workerId});
  final int workerId;
}

class _WorkerErrorMessage extends _WorkerMessage {
  _WorkerErrorMessage({
    required this.workerId,
    this.failedKey,
    this.filePath,
    required this.errorMessage,
    this.stackTrace,
  });
  final int workerId;
  final String? failedKey;
  final String? filePath;
  final String errorMessage;
  final String? stackTrace;
}

sealed class _MainMessage {
  const _MainMessage();
}

class _MainTaskMessage extends _MainMessage {
  _MainTaskMessage({required this.input});
  final _TransferableInput input;
}

class _MainShutdownMessage extends _MainMessage {
  const _MainShutdownMessage();
}

/// Exception thrown when image analysis fails in an isolate.
class AnalysisException implements Exception {
  AnalysisException(this.message, {this.itemKey, this.filePath, this.cause});
  final String message;
  final String? itemKey;
  final String? filePath;
  final Object? cause;

  @override
  String toString() => message;
}

