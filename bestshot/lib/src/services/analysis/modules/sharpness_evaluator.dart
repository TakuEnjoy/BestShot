import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

class SharpnessEvaluator {
  static (double, List<double>) calcLaplacianVarianceFromMat(
    cv.Mat bgr,
    Uint8List? bytes,
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
            debugPrint('Error in cell calcLaplacianVarianceFromMat: $e');
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
      debugPrint('Error in calcLaplacianVarianceFromMat: $e\n$s');
      final fb = bytes != null ? fallbackLaplacianVariance(bytes) : 0.0;
      return (fb, List.filled(16, fb));
    } finally {
      gray?.dispose();
    }
  }

  static double calcLaplacianVarianceInRoi(cv.Mat bgr, cv.Rect roi) {
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
      debugPrint('Error in calcLaplacianVarianceInRoi: $e\n$s');
      return 0;
    } finally {
      sub?.dispose();
      gray?.dispose();
      lap?.dispose();
    }
  }

  static double fallbackLaplacianVariance(
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
      debugPrint('Error in fallbackLaplacianVariance: $e\n$s');
      return 0;
    }
  }
}
