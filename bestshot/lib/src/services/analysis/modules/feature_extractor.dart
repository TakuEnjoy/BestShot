import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

class OrbDesc {
  const OrbDesc({required this.rows, required this.cols, required this.bytes});
  OrbDesc.empty() : rows = 0, cols = 0, bytes = Uint8List(0);
  final int rows;
  final int cols;
  final Uint8List bytes;
}

class FeatureExtractor {
  static OrbDesc calcOrbDescriptorsFromMat(cv.Mat mat) {
    cv.Mat? gray;
    cv.Mat? eq;
    cv.Mat? desc;
    try {
      gray = cv.cvtColor(mat, cv.COLOR_BGR2GRAY);
      eq = cv.equalizeHist(gray);

      final orb = cv.ORB.create(nFeatures: 600, scaleFactor: 1.2, nLevels: 8);
      final result = orb.detectAndCompute(eq, cv.Mat.empty());
      desc = result.$2;
      if (desc.isEmpty) return OrbDesc.empty();
      final rows = desc.rows > 256 ? 256 : desc.rows;
      final cols = desc.cols;
      final elemSize = desc.elemSize;
      final bytesLen = rows * cols * elemSize;
      final all = desc.data;
      if (all.length < bytesLen) return OrbDesc.empty();
      final sliced = Uint8List.fromList(all.sublist(0, bytesLen));
      return OrbDesc(rows: rows, cols: cols, bytes: sliced);
    } catch (e, s) {
      debugPrint('Error in calcOrbDescriptorsFromMat: $e\n$s');
      return OrbDesc.empty();
    } finally {
      gray?.dispose();
      eq?.dispose();
      desc?.dispose();
    }
  }
}
