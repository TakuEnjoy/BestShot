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

    // 1. 安定した基本ロジック
    gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);
    lap = cv.laplacian(gray, cv.MatType.CV_64F);
    absLap = cv.convertScaleAbs(lap);
    blurred = cv.gaussianBlur(absLap, (15, 15), 0);

    final otsu = cv.threshold(
      blurred,
      0,
      255,
      cv.THRESH_BINARY | cv.THRESH_OTSU,
    );
    binSmall = otsu.$2;

    // 2. 元の解像度にリサイズ
    binFull = cv.resize(binSmall, (
      origW,
      origH,
    ), interpolation: cv.INTER_NEAREST);

    // 3. シンプルな白黒PNGを返す（元の実装に戻す）
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
