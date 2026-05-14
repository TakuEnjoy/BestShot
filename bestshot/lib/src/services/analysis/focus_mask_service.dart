import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Laplacian-based binary mask: in-focus ≈ white, out-of-focus ≈ black.
/// Runs synchronously; call via [compute] from UI isolate.
Uint8List? focusMaskPngFromBytes(Uint8List bytes) {
  cv.Mat? mat;
  cv.Mat? work;
  cv.Mat? gray;
  cv.Mat? lap;
  cv.Mat? absLap;
  cv.Mat? blurred;
  cv.Mat? norm;
  cv.Mat? binSmall;
  cv.Mat? dilated;
  cv.Mat? binFull;
  try {
    mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (mat.isEmpty) return null;

    final origW = mat.cols;
    final origH = mat.rows;
    const maxEdge = 960;

    if (origW > maxEdge || origH > maxEdge) {
      final scale = maxEdge / (origW > origH ? origW : origH);
      final nw = (origW * scale).round();
      final nh = (origH * scale).round();
      work = cv.resize(mat, (nw, nh));
    } else {
      work = mat.clone();
    }

    // 1. グレースケール変換
    gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);

    // 2. Laplacianで輪郭・高周波（ピント部）を抽出
    lap = cv.laplacian(gray, cv.MatType.CV_64F);
    absLap = cv.convertScaleAbs(lap);

    // 3. ガウシアンブラーでノイズ除去（ブロック単位の評価に近づける）
    blurred = cv.gaussianBlur(absLap, (15, 15), 0);

    // 4. 0〜255に正規化（Otsuの前に輝度分布を広げる）
    //    これがないと全ピクセルが暗い輝度帯に集中してOtsuが全白になる
    norm = cv.Mat.zeros(blurred.rows, blurred.cols, cv.MatType.CV_8UC1);
    cv.normalize(
      blurred,
      norm,
      alpha: 0,
      beta: 255,
      normType: cv.NORM_MINMAX,
      dtype: cv.MatType.CV_8UC1.value,
    );

    // 5. Otsu二値化（正規化後なら輝度分布が二峰性になりやすい）
    final otsu = cv.threshold(
      norm,
      0,
      255,
      cv.THRESH_BINARY | cv.THRESH_OTSU,
    );
    binSmall = otsu.$2;

    // 6. 膨張処理でピント領域の穴埋め（小さい孤立ノイズは無視）
    final kernel = cv.getStructuringElement(
      cv.MORPH_ELLIPSE,
      (15, 15),
    );
    dilated = cv.dilate(binSmall, kernel);

    // 7. 元の解像度に戻す
    binFull = cv.resize(dilated, (origW, origH),
        interpolation: cv.INTER_NEAREST);

    final encodeResult = cv.imencode('.png', binFull);
    return encodeResult.$2;
  } catch (_) {
    return null;
  } finally {
    mat?.dispose();
    work?.dispose();
    gray?.dispose();
    lap?.dispose();
    absLap?.dispose();
    blurred?.dispose();
    norm?.dispose();
    binSmall?.dispose();
    dilated?.dispose();
    binFull?.dispose();
  }
}
