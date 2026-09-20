import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/photo_entry.dart';
import 'native_face_detector.dart';

class MlKitSemanticService {
  MlKitSemanticService._(this._faceDetector);

  final NativeFaceDetector _faceDetector;

  static Future<MlKitSemanticService> create() async {
    return MlKitSemanticService._(NativeFaceDetector());
  }

  Future<void> close() async {
    await _faceDetector.close();
  }

  Future<List<PhotoEntry>> enrich(
    List<PhotoEntry> entries, {
    void Function(int done, int total)? onProgress,
    int maxEdge = 640,
    bool Function()? isCancelled,
  }) async {
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
    final uniqueId = '${DateTime.now().millisecondsSinceEpoch}_${e.key.hashCode}';
    final fp = p.join(tmp.path, 'bestshot_$uniqueId.jpg');
    try {
      final bytes = e.displayBytes;
      await File(fp).writeAsBytes(bytes, flush: true);

      final faces = await _faceDetector.processImage(fp);
      final faceScore = _faceQualityScore(faces);

      return e.copyWith(
        semanticObjects: const [], // Object detection removed for iOS native rewrite
        faceQualityScore: faceScore,
      );
    } catch (err, stack) {
      developer.log('Error in semantic processing: $err\n$stack');
      return e;
    } finally {
      try {
        final f = File(fp);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
  }

  static double _faceQualityScore(List<NativeFace> faces) {
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
