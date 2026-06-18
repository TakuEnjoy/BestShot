import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/photo_entry.dart';

class MlKitSemanticService {
  MlKitSemanticService._(this._objectDetector, this._faceDetector);

  final ObjectDetector _objectDetector;
  final FaceDetector _faceDetector;

  static Future<MlKitSemanticService> create() async {
    final objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      ),
    );
    final faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    return MlKitSemanticService._(objectDetector, faceDetector);
  }

  Future<void> close() async {
    await _objectDetector.close();
    await _faceDetector.close();
  }

  Future<List<PhotoEntry>> enrich(
    List<PhotoEntry> entries, {
    void Function(int done, int total)? onProgress,
    int maxEdge = 640,
  }) async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return entries;
    }

    final tmp = await getTemporaryDirectory();
    final out = <PhotoEntry>[];
    var done = 0;
    for (final e in entries) {
      final enriched = await _enrichOne(e, tmp, maxEdge: maxEdge);
      out.add(enriched);
      done++;
      onProgress?.call(done, entries.length);
    }
    return out;
  }

  Future<PhotoEntry> _enrichOne(
    PhotoEntry e,
    Directory tmp, {
    required int maxEdge,
  }) async {
    try {
      final resizedBytes = await _resizeForMlKit(
        e.displayBytes,
        maxEdge: maxEdge,
      );
      final fp = p.join(tmp.path, 'bestshot_${e.key.hashCode}.jpg');
      await File(fp).writeAsBytes(resizedBytes, flush: true);
      final input = InputImage.fromFilePath(fp);

      final objects = await _objectDetector.processImage(input);
      final semantic = _toSemanticObjects(objects, resizedBytes);

      final faces = await _faceDetector.processImage(input);
      final faceScore = _faceQualityScore(faces);

      var updatedSharpness = e.sharpness;
      if (objects.isNotEmpty) {
        DetectedObject? mainObj;
        double maxArea = 0;
        for (final o in objects) {
          final area = o.boundingBox.width * o.boundingBox.height;
          if (area > maxArea) {
            maxArea = area.toDouble();
            mainObj = o;
          }
        }

        if (mainObj != null) {
          final mlImage = img.decodeImage(resizedBytes);
          if (mlImage != null) {
            final mlW = mlImage.width;
            final mlH = mlImage.height;

            cv.Mat? mat;
            try {
              if (e.filePath != null && await File(e.filePath!).exists()) {
                mat = cv.imread(e.filePath!);
              } else {
                mat = cv.imdecode(e.displayBytes, cv.IMREAD_COLOR);
              }

              if (!mat.isEmpty && mlW > 0 && mlH > 0) {
                final origW = mat.cols;
                final origH = mat.rows;
                final bb = mainObj.boundingBox;

                final rx = (bb.left / mlW * origW).round().clamp(0, origW - 1);
                final ry = (bb.top / mlH * origH).round().clamp(0, origH - 1);
                final rw = (bb.width / mlW * origW).round().clamp(1, origW - rx);
                final rh = (bb.height / mlH * origH).round().clamp(1, origH - ry);

                final objSharpness = _calcLaplacianVarianceInRoi(mat, cv.Rect(rx, ry, rw, rh));
                if (objSharpness > 0) {
                  updatedSharpness = objSharpness;
                }
              }
            } catch (_) {
              // Keep original sharpness
            } finally {
              mat?.dispose();
            }
          }
        }
      }

      return e.copyWith(
        semanticObjects: semantic,
        faceQualityScore: faceScore,
        sharpness: updatedSharpness,
      );
    } catch (_) {
      return e;
    }
  }

  static Future<Uint8List> _resizeForMlKit(
    Uint8List bytes, {
    required int maxEdge,
  }) async {
    return Isolate.run(() {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      final upright = img.bakeOrientation(decoded);
      final w = upright.width;
      final h = upright.height;
      if (w <= maxEdge && h <= maxEdge) return bytes;
      final resized = img.copyResize(
        upright,
        width: w >= h ? maxEdge : null,
        height: h > w ? maxEdge : null,
      );
      return Uint8List.fromList(img.encodeJpg(resized, quality: 90));
    });
  }

  static List<SemanticObject> _toSemanticObjects(
    List<DetectedObject> objects,
    Uint8List jpgBytes,
  ) {
    final decoded = img.decodeImage(jpgBytes);
    if (decoded == null) return const [];
    final w = decoded.width.toDouble();
    final h = decoded.height.toDouble();
    if (w <= 0 || h <= 0) return const [];

    final out = <SemanticObject>[];
    for (final o in objects) {
      final label = o.labels.isNotEmpty ? o.labels.first.text : 'Object';
      final bb = o.boundingBox;
      final x = (bb.left / w).clamp(0.0, 1.0);
      final y = (bb.top / h).clamp(0.0, 1.0);
      final ww = (bb.width / w).clamp(0.0, 1.0);
      final hh = (bb.height / h).clamp(0.0, 1.0);
      out.add(SemanticObject(label: label, x: x, y: y, w: ww, h: hh));
    }
    return out;
  }

  static double _faceQualityScore(List<Face> faces) {
    double best = 0;
    for (final f in faces) {
      final s = f.smilingProbability;
      final le = f.leftEyeOpenProbability;
      final re = f.rightEyeOpenProbability;
      final parts = <double>[];
      if (s != null) parts.add(s);
      if (le != null) parts.add(le);
      if (re != null) parts.add(re);
      if (parts.isEmpty) continue;
      final avg = parts.reduce((a, b) => a + b) / parts.length;
      if (avg > best) best = avg;
    }
    return best.clamp(0.0, 1.0);
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
}
