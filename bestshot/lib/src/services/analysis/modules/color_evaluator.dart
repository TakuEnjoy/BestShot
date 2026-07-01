import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

class ColorEvaluator {
  static Float32List? calcHueHistogramFromMat(cv.Mat bgr) {
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
      cv.normalize(
        histH,
        histHNorm,
        alpha: 1.0,
        beta: 0.0,
        normType: cv.NORM_L1,
      );

      // 2. Saturation Hist (256 bins)
      histS = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([1]),
        mask,
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      histSNorm = cv.Mat.empty();
      cv.normalize(
        histS,
        histSNorm,
        alpha: 1.0,
        beta: 0.0,
        normType: cv.NORM_L1,
      );

      // 3. Value Hist (256 bins)
      histV = cv.calcHist(
        cv.VecMat.fromList([hsv]),
        cv.VecI32.fromList([2]),
        mask,
        cv.VecI32.fromList([256]),
        cv.VecF32.fromList([0, 256]),
      );
      histVNorm = cv.Mat.empty();
      cv.normalize(
        histV,
        histVNorm,
        alpha: 1.0,
        beta: 0.0,
        normType: cv.NORM_L1,
      );

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
      debugPrint('Error in calcHueHistogramFromMat: $e\n$s');
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
}
