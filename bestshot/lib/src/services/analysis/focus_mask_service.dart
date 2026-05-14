import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Laplacian-based binary mask: in-focus ≈ white, out-of-focus ≈ black.
/// Runs synchronously; call via [compute] from UI isolate.
///
/// 精密化方針:
///   - マルチスケールLaplacian（3種のkernelサイズ）で細部〜大域のピントを両方捉える
///   - normalize → Otsu で確実に二値化
///   - モルフォロジー: open（ノイズ除去）→ close（穴埋め）→ Canny guided refine（境界シャープ化）
Uint8List? focusMaskPngFromBytes(Uint8List bytes) {
  cv.Mat? mat;
  cv.Mat? work;
  cv.Mat? gray;

  // マルチスケールLaplacian用
  cv.Mat? lap1;
  cv.Mat? lap2;
  cv.Mat? lap3;
  cv.Mat? abs1;
  cv.Mat? abs2;
  cv.Mat? abs3;
  cv.Mat? merged;

  // ブラー・正規化
  cv.Mat? blurred;
  cv.Mat? norm;

  // 二値化・モルフォロジー
  cv.Mat? binary;
  cv.Mat? opened;
  cv.Mat? closed;

  // Cannyエッジガイド
  cv.Mat? canny;
  cv.Mat? cannyDilated;
  cv.Mat? refined;

  // 出力
  cv.Mat? binFull;

  try {
    mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (mat.isEmpty) return null;

    final origW = mat.cols;
    final origH = mat.rows;
    const maxEdge = 960;

    if (origW > maxEdge || origH > maxEdge) {
      final scale = maxEdge / (origW > origH ? origW : origH);
      work = cv.resize(mat, (
        (origW * scale).round(),
        (origH * scale).round(),
      ));
    } else {
      work = mat.clone();
    }

    // ── Step 1: グレースケール ──────────────────────────────────────────
    gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);

    // ── Step 2: マルチスケールLaplacian ────────────────────────────────
    // ksize=1: 細かいテクスチャ（睫毛・髪の毛など）
    // ksize=3: 標準的なピント評価
    // ksize=5: 大域的なピント（大きなボケとシャープの境界）
    lap1 = cv.laplacian(gray, cv.MatType.CV_64F, ksize: 1);
    lap2 = cv.laplacian(gray, cv.MatType.CV_64F, ksize: 3);
    lap3 = cv.laplacian(gray, cv.MatType.CV_64F, ksize: 5);

    abs1 = cv.convertScaleAbs(lap1);
    abs2 = cv.convertScaleAbs(lap2);
    abs3 = cv.convertScaleAbs(lap3);

    // 3スケールを加重合成（細部重視: 50% / 35% / 15%）
    merged = cv.Mat.zeros(gray.rows, gray.cols, cv.MatType.CV_8UC1);
    cv.addWeighted(abs1, 0.50, abs2, 0.35, 0, dst: merged);
    cv.addWeighted(merged, 1.0, abs3, 0.15, 0, dst: merged);

    // ── Step 3: ガウシアンブラー（境界をぼかしすぎないよう小さめ）────────
    blurred = cv.gaussianBlur(merged, (9, 9), 0);

    // ── Step 4: 正規化 → Otsu二値化 ────────────────────────────────────
    norm = cv.Mat.zeros(blurred.rows, blurred.cols, cv.MatType.CV_8UC1);
    cv.normalize(
      blurred,
      norm,
      alpha: 0,
      beta: 255,
      normType: cv.NORM_MINMAX,
      dtype: cv.MatType.CV_8UC1.value,
    );

    final otsu = cv.threshold(
      norm,
      0,
      255,
      cv.THRESH_BINARY | cv.THRESH_OTSU,
    );
    binary = otsu.$2;

    // ── Step 5: モルフォロジー（ノイズ除去 → 穴埋め）──────────────────
    // open: 孤立した小ノイズ・誤検出を除去
    final kernelOpen = cv.getStructuringElement(cv.MORPH_ELLIPSE, (7, 7));
    opened = cv.morphologyEx(binary, cv.MORPH_OPEN, kernelOpen);

    // close: ピント領域内の細かい穴を埋めて塊にする
    final kernelClose = cv.getStructuringElement(cv.MORPH_ELLIPSE, (19, 19));
    closed = cv.morphologyEx(opened, cv.MORPH_CLOSE, kernelClose);

    // ── Step 6: Cannyエッジで境界をシャープ化 ──────────────────────────
    // 元グレー画像からエッジを検出し、境界帯だけ細部（binary）を復元する
    canny = cv.canny(gray, 40, 120);

    // エッジを少し太らせて「境界帯」を定義
    final kernelCanny = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    cannyDilated = cv.dilate(canny, kernelCanny);

    // 境界帯 → binary（細かい判定）、それ以外 → closed（安定した領域）
    refined = closed.clone();
    final closedData = closed.data;
    final binaryData = binary.data;
    final cannyData = cannyDilated.data;
    final refinedData = refined.data;

    for (var idx = 0; idx < refinedData.length; idx++) {
      if (cannyData[idx] > 0) {
        refinedData[idx] = binaryData[idx];
      }
    }

    // ── Step 7: 元解像度に戻す ─────────────────────────────────────────
    // INTER_NEARESTで二値の白黒をそのまま保持（補間でグレーにしない）
    binFull = cv.resize(
      refined,
      (origW, origH),
      interpolation: cv.INTER_NEAREST,
    );

    final encodeResult = cv.imencode('.png', binFull);
    return encodeResult.$2;
  } catch (_) {
    return null;
  } finally {
    mat?.dispose();
    work?.dispose();
    gray?.dispose();
    lap1?.dispose();
    lap2?.dispose();
    lap3?.dispose();
    abs1?.dispose();
    abs2?.dispose();
    abs3?.dispose();
    merged?.dispose();
    blurred?.dispose();
    norm?.dispose();
    binary?.dispose();
    opened?.dispose();
    closed?.dispose();
    canny?.dispose();
    cannyDilated?.dispose();
    refined?.dispose();
    binFull?.dispose();
  }
}
