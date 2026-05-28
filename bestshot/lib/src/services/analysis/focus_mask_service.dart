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
  cv.Mat? kernelOpen;
  cv.Mat? kernelClose;

  // Cannyエッジガイド
  cv.Mat? canny;
  cv.Mat? cannyDilated;
  cv.Mat? kernelCanny;
  cv.Mat? borderPart;
  cv.Mat? notCanny;
  cv.Mat? nonBorderPart;
  cv.Mat? refined;

  // 出力
  cv.Mat? binFull;
  cv.Mat? white;
  cv.VecMat? channels;
  cv.Mat? rgba;

  try {
    mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (mat.isEmpty) return null;

    final origW = mat.cols;
    final origH = mat.rows;
    
    // Performance improvement: Run on original full resolution to capture pixel-level focus.
    work = mat.clone();

    // Scale parameter based on the reference resolution (960px max edge).
    final maxD = origW > origH ? origW : origH;
    final scale = maxD / 960.0;

    // ── Step 1: グレースケール ──────────────────────────────────────────
    gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);

    // ── Step 2: マルチスケールLaplacian ────────────────────────────────
    // ksize=1: 細かいテクスチャ
    // ksize=3: 標準的なピント評価
    // ksize=5: 大域的なピント
    lap1 = cv.laplacian(gray, cv.MatType.CV_64F, ksize: 1);
    lap2 = cv.laplacian(gray, cv.MatType.CV_64F, ksize: 3);
    lap3 = cv.laplacian(gray, cv.MatType.CV_64F, ksize: 5);

    abs1 = cv.convertScaleAbs(lap1);
    abs2 = cv.convertScaleAbs(lap2);
    abs3 = cv.convertScaleAbs(lap3);

    // 3スケールを加重合成（高周波ノイズ低減のため安定性重視へ調整：25% / 50% / 25%）
    merged = cv.Mat.zeros(gray.rows, gray.cols, cv.MatType.CV_8UC1);
    cv.addWeighted(abs1, 0.25, abs2, 0.50, 0, dst: merged);
    cv.addWeighted(merged, 1.0, abs3, 0.25, 0, dst: merged);

    // ── Step 3: ガウシアンブラー（解像度に応じて動的スケーリング）────────
    int blurSize = (9 * scale).round();
    if (blurSize % 2 == 0) blurSize++;
    if (blurSize < 3) blurSize = 3;
    blurred = cv.gaussianBlur(merged, (blurSize, blurSize), 0);

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

    // ── Step 5: モルフォロジー（ノイズ除去 → 穴埋め、解像度に応じて動的スケーリング）────────
    // open: 孤立した小ノイズ・誤検出を除去
    int openSize = (7 * scale).round();
    if (openSize < 3) openSize = 3;
    kernelOpen = cv.getStructuringElement(cv.MORPH_ELLIPSE, (openSize, openSize));
    opened = cv.morphologyEx(binary, cv.MORPH_OPEN, kernelOpen);

    // close: ピント領域内の細かい穴を埋めて塊にする
    int closeSize = (19 * scale).round();
    if (closeSize < 3) closeSize = 3;
    kernelClose = cv.getStructuringElement(cv.MORPH_ELLIPSE, (closeSize, closeSize));
    closed = cv.morphologyEx(opened, cv.MORPH_CLOSE, kernelClose);

    // ── Step 6: Cannyエッジで境界をシャープ化 ──────────────────────────
    // 元グレー画像からエッジを検出し、境界帯だけ細部（binary）を復元する
    canny = cv.canny(gray, 40, 120);

    // エッジを少し太らせて「境界帯」を定義
    int cannyDilateSize = (3 * scale).round();
    if (cannyDilateSize < 1) cannyDilateSize = 1;
    kernelCanny = cv.getStructuringElement(cv.MORPH_RECT, (cannyDilateSize, cannyDilateSize));
    cannyDilated = cv.dilate(canny, kernelCanny);

    // 境界帯 → binary（細かい判定）、それ以外 → closed（安定した領域）
    // ビット演算を用いて結合
    borderPart = cv.bitwiseAND(binary, cannyDilated);
    notCanny = cv.bitwiseNOT(cannyDilated);
    nonBorderPart = cv.bitwiseAND(closed, notCanny);
    refined = cv.bitwiseOR(borderPart, nonBorderPart);

    // ── Step 7: 元解像度に戻す ─────────────────────────────────────────
    // すでに元解像度で計算されているため、そのまま clone
    binFull = refined.clone();

    // ── Step 8: 透過RGBA画像の作成 ──────────────────────────────────────
    // R=255, G=255, B=255, A=binFull (白=不透明, 黒=透明)
    white = cv.Mat.fromScalar(origH, origW, cv.MatType.CV_8UC1, cv.Scalar.all(255));
    channels = cv.VecMat.fromList([white, white, white, binFull]);
    rgba = cv.merge(channels);

    final encodeResult = cv.imencode('.png', rgba);
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
    kernelOpen?.dispose();
    kernelClose?.dispose();
    canny?.dispose();
    cannyDilated?.dispose();
    kernelCanny?.dispose();
    borderPart?.dispose();
    notCanny?.dispose();
    nonBorderPart?.dispose();
    refined?.dispose();
    binFull?.dispose();
    white?.dispose();
    channels?.dispose();
    rgba?.dispose();
  }
}
