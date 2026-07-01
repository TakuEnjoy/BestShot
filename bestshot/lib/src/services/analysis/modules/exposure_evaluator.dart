import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

class ExposureEvaluator {
  static (double, Uint8List) calcExposureAndHistogramFromMat(cv.Mat bgr) {
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
      debugPrint('Error in calcExposureAndHistogramFromMat: $e\n$s');
      return (0.0, Uint8List(256));
    } finally {
      gray?.dispose();
      hist?.dispose();
    }
  }
}
