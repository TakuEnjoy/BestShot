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
  cv.Mat? binSmall;
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

    gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);
    lap = cv.laplacian(gray, cv.MatType.CV_64F);

    // コントラストを強調しつつ、エッジ強度を絶対値に変換 (alpha: 5.0 で信号を増幅)
    absLap = cv.convertScaleAbs(lap, alpha: 5.0);

    // ガウシアンブラーでノイズ平滑化
    blurred = cv.gaussianBlur(absLap, (15, 15), 0);

    // 最低限のノイズカット（エッジ強度が低い部分を 0 に落とす）
    // これにより、全体が低コントラストな場合に Otsu が閾値を 0 にしてしまうのを防ぐ
    final noiseCut = cv.threshold(blurred, 15, 255, cv.THRESH_TOZERO);
    final processed = noiseCut.$2;

    final otsu = cv.threshold(
      processed,
      0,
      255,
      cv.THRESH_BINARY | cv.THRESH_OTSU,
    );
    binSmall = otsu.$2;

    binFull = cv.resize(binSmall, (
      origW,
      origH,
    ), interpolation: cv.INTER_NEAREST);
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
    binSmall?.dispose();
    binFull?.dispose();
  }
}
