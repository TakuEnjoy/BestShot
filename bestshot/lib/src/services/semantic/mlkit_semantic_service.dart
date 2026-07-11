import 'dart:developer' as developer;
import 'dart:io';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;
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
    bool Function()? isCancelled,
  }) async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return entries;
    }

    final tmp = await getTemporaryDirectory();
    final out = <PhotoEntry>[];
    var done = 0;
    for (final e in entries) {
      if (isCancelled?.call() == true) {
        break;
      }
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
    final uniqueId =
        '${DateTime.now().millisecondsSinceEpoch}_${e.key.hashCode}';
    final fp = p.join(tmp.path, 'bestshot_$uniqueId.jpg');
    try {
      final bytes = e.displayBytes;
      await File(fp).writeAsBytes(bytes, flush: true);
      final input = InputImage.fromFilePath(fp);

      final objects = await _objectDetector.processImage(input);
      final faces = await _faceDetector.processImage(input);
      final faceScore = _faceQualityScore(faces);

      if (objects.isEmpty) {
        return e.copyWith(
          semanticObjects: const [],
          faceQualityScore: faceScore,
        );
      }

      // Decode once to get the dimensions of displayBytes
      final decoder = img.findDecoderForData(bytes);
      final decoded = decoder?.startDecode(bytes);
      if (decoded == null) {
        return e.copyWith(
          semanticObjects: const [],
          faceQualityScore: faceScore,
        );
      }
      final w = decoded.width.toDouble();
      final h = decoded.height.toDouble();

      final semantic = <SemanticObject>[];
      DetectedObject? mainObj;
      double maxArea = 0;

      for (final o in objects) {
        final label = o.labels.isNotEmpty ? o.labels.first.text : 'Object';
        final bb = o.boundingBox;
        final x = (bb.left / w).clamp(0.0, 1.0);
        final y = (bb.top / h).clamp(0.0, 1.0);
        final ww = (bb.width / w).clamp(0.0, 1.0);
        final hh = (bb.height / h).clamp(0.0, 1.0);
        semantic.add(SemanticObject(label: label, x: x, y: y, w: ww, h: hh));

        final area = bb.width * bb.height;
        if (area > maxArea) {
          maxArea = area.toDouble();
          mainObj = o;
        }
      }

      var updatedSharpness = e.sharpness;
      if (mainObj != null &&
          e.debugGridSharps != null &&
          e.debugGridSharps!.isNotEmpty) {
        final bb = mainObj.boundingBox;
        final ox = (bb.left / w).clamp(0.0, 1.0);
        final oy = (bb.top / h).clamp(0.0, 1.0);
        final ow = (bb.width / w).clamp(0.0, 1.0);
        final oh = (bb.height / h).clamp(0.0, 1.0);

        final objSharpness = _estimateObjectSharpness(
          e.debugGridSharps!,
          ox,
          oy,
          ow,
          oh,
        );
        if (objSharpness > 0) {
          updatedSharpness = objSharpness;
        }
      }

      return e.copyWith(
        semanticObjects: semantic,
        faceQualityScore: faceScore,
        sharpness: updatedSharpness,
      );
    } catch (err, stack) {
      developer.log('Error in MLKit semantic processing: $err\n$stack');
      return e;
    } finally {
      // Clean up the temp file
      try {
        final f = File(fp);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
  }

  static double _estimateObjectSharpness(
    List<double> gridSharps,
    double ox,
    double oy,
    double ow,
    double oh,
  ) {
    if (gridSharps.length < 16) return 0.0;
    double totalWeight = 0.0;
    double weightedSharpness = 0.0;

    for (int r = 0; r < 4; r++) {
      for (int c = 0; c < 4; c++) {
        double cx1 = c * 0.25;
        double cy1 = r * 0.25;
        double cx2 = cx1 + 0.25;
        double cy2 = cy1 + 0.25;

        double ox1 = ox;
        double oy1 = oy;
        double ox2 = ox + ow;
        double oy2 = oy + oh;

        double ix1 = cx1 > ox1 ? cx1 : ox1;
        double iy1 = cy1 > oy1 ? cy1 : oy1;
        double ix2 = cx2 < ox2 ? cx2 : ox2;
        double iy2 = cy2 < oy2 ? cy2 : oy2;

        double iw = ix2 - ix1;
        double ih = iy2 - iy1;

        if (iw > 0 && ih > 0) {
          double overlap = iw * ih;
          int idx = r * 4 + c;
          weightedSharpness += gridSharps[idx] * overlap;
          totalWeight += overlap;
        }
      }
    }
    if (totalWeight > 0) {
      return weightedSharpness / totalWeight;
    }
    return 0.0;
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
}
