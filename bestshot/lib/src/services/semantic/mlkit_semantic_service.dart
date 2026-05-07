import 'dart:io';
import 'dart:typed_data';

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

      return e.copyWith(semanticObjects: semantic, faceQualityScore: faceScore);
    } catch (_) {
      return e;
    }
  }

  static Future<Uint8List> _resizeForMlKit(
    Uint8List bytes, {
    required int maxEdge,
  }) async {
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
}
