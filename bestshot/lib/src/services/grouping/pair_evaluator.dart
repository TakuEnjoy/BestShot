import 'dart:math' as math;
import 'dart:typed_data';
import '../../models/photo_entry.dart';
import 'orb_matcher.dart';

enum PairCategory {
  sameBurst,                 // 短時間連写 (0-2秒, 局所特徴・pHash近接)
  sameSceneVariant,          // 同一シーンの寄り・引き・ズーム・構図差・撮り直し (RANSAC幾何またはクロップ埋め込み主証拠)
  sameSubjectDifferentEvent, // 同じ被写体だが別イベント (検索用関連付けのみ。削除グループには絶対結合しない)
  different,                 // 明らかに別写真
}

class PairSimilarityResult {
  const PairSimilarityResult({
    required this.category,
    required this.isSameScene,
    required this.confidence,
    required this.needsReview,
    this.diffSeconds,
    this.pHashDistance,
    this.colorDistance,
    this.orbGoodMatches,
    this.orbInliers,
    this.orbInlierRatio,
    this.embeddingSimilarity,
    this.cropPair,
    this.semanticMatch = false,
    required this.explanation,
  });

  final PairCategory category;
  final bool isSameScene;
  final double confidence;
  final bool needsReview;
  
  final double? diffSeconds;
  final int? pHashDistance;
  final double? colorDistance;
  final int? orbGoodMatches;
  final int? orbInliers;
  final double? orbInlierRatio;
  final double? embeddingSimilarity;
  final String? cropPair;
  final bool semanticMatch;
  final String explanation;
}

class PairSimilarityEvaluator {
  /// Evaluates two photos and returns a structured, explainable PairSimilarityResult.
  static PairSimilarityResult evaluate(
    PhotoEntry a,
    PhotoEntry b, {
    int burstWindowSeconds = 15,
  }) {
    final ta = a.capturedAt;
    final tb = b.capturedAt;

    final double? diffSeconds = (ta != null && tb != null)
        ? (ta.difference(tb).inMilliseconds.abs() / 1000.0)
        : null;

    final pHashDist = _calcPHashDistance(a, b);
    final colorDist = _calcColorDistance(a, b);
    
    // ORB with RANSAC & geometric plausibility checks
    final (inliers, inlierRatio, goodMatches) = OrbMatcher.computeInliers(
      rowsA: a.orbRows,
      bytesA: a.orbBytes,
      keypointsA: a.orbKeypoints,
      rowsB: b.orbRows,
      bytesB: b.orbBytes,
      keypointsB: b.orbKeypoints,
    );

    // Multi-crop embedding similarity
    final (embSim, bestCropPair) = _calcBestEmbeddingSimilarity(a, b);

    // Semantic object matching (face/object labels)
    final isSemMatch = _semanticSimilar(a, b);

    // -------------------------------------------------------------
    // Category 1: sameBurst (短時間連写)
    // -------------------------------------------------------------
    // Ultra-burst: <= 0.8s, almost guaranteed burst
    if (diffSeconds != null && diffSeconds <= 0.8) {
      if (pHashDist != null && pHashDist <= 14) {
        return PairSimilarityResult(
          category: PairCategory.sameBurst,
          isSameScene: true,
          confidence: 0.98,
          needsReview: false,
          diffSeconds: diffSeconds,
          pHashDistance: pHashDist,
          colorDistance: colorDist,
          orbGoodMatches: goodMatches,
          orbInliers: inliers,
          orbInlierRatio: inlierRatio,
          embeddingSimilarity: embSim,
          cropPair: bestCropPair,
          semanticMatch: isSemMatch,
          explanation: '高速連写 (${diffSeconds.toStringAsFixed(2)}s差, pHash: $pHashDist)',
        );
      }
    }

    // Standard burst: within burst window
    if (diffSeconds != null && diffSeconds <= burstWindowSeconds) {
      // If pHash is close OR inliers are strong
      if (pHashDist != null && pHashDist <= 10) {
        final needsReview = pHashDist >= 8 && (colorDist != null && colorDist > 0.35);
        return PairSimilarityResult(
          category: PairCategory.sameBurst,
          isSameScene: true,
          confidence: (1.0 - (pHashDist / 20.0)).clamp(0.70, 0.95),
          needsReview: needsReview,
          diffSeconds: diffSeconds,
          pHashDistance: pHashDist,
          colorDistance: colorDist,
          orbGoodMatches: goodMatches,
          orbInliers: inliers,
          orbInlierRatio: inlierRatio,
          embeddingSimilarity: embSim,
          cropPair: bestCropPair,
          semanticMatch: isSemMatch,
          explanation: '連写 (${diffSeconds.toStringAsFixed(1)}s差, 類似度高)',
        );
      }

      // Strong local geometric inliers in burst window
      if (inliers >= 12 && inlierRatio >= 0.15) {
        return PairSimilarityResult(
          category: PairCategory.sameBurst,
          isSameScene: true,
          confidence: 0.92,
          needsReview: false,
          diffSeconds: diffSeconds,
          pHashDistance: pHashDist,
          colorDistance: colorDist,
          orbGoodMatches: goodMatches,
          orbInliers: inliers,
          orbInlierRatio: inlierRatio,
          embeddingSimilarity: embSim,
          cropPair: bestCropPair,
          semanticMatch: isSemMatch,
          explanation: '連写・局所幾何一致 (Inliers: $inliers点)',
        );
      }
    }

    // -------------------------------------------------------------
    // Category 2: sameSceneVariant (同一シーンの寄り・引き・ズーム・構図差・撮り直し)
    // -------------------------------------------------------------
    // Condition A: Strong RANSAC Inliers with valid Homography
    // Color histogram is NOT a hard exclusion here!
    if (inliers >= 12 && inlierRatio >= 0.15) {
      final isDifferentDay = (diffSeconds != null && diffSeconds > 3600 * 6);
      if (!isDifferentDay) {
        final confidence = (0.75 + (inliers / 100.0)).clamp(0.75, 0.96);
        final needsReview = inliers < 18 || (diffSeconds != null && diffSeconds > 300);
        return PairSimilarityResult(
          category: PairCategory.sameSceneVariant,
          isSameScene: true,
          confidence: confidence,
          needsReview: needsReview,
          diffSeconds: diffSeconds,
          pHashDistance: pHashDist,
          colorDistance: colorDist,
          orbGoodMatches: goodMatches,
          orbInliers: inliers,
          orbInlierRatio: inlierRatio,
          embeddingSimilarity: embSim,
          cropPair: bestCropPair,
          semanticMatch: isSemMatch,
          explanation: '寄り引き/ズーム幾何一致 (Inliers: $inliers点, 率: ${(inlierRatio * 100).toStringAsFixed(1)}%)',
        );
      }
    }

    // Condition B: High Crop Embedding Similarity (Zoom / Framing difference)
    if (embSim != null && embSim >= 0.82) {
      // Must be within same session/event (< 15 mins)
      final withinSession = (diffSeconds == null || diffSeconds <= 900);
      if (withinSession) {
        final needsReview = embSim < 0.88;
        return PairSimilarityResult(
          category: PairCategory.sameSceneVariant,
          isSameScene: true,
          confidence: embSim.clamp(0.70, 0.95),
          needsReview: needsReview,
          diffSeconds: diffSeconds,
          pHashDistance: pHashDist,
          colorDistance: colorDist,
          orbGoodMatches: goodMatches,
          orbInliers: inliers,
          orbInlierRatio: inlierRatio,
          embeddingSimilarity: embSim,
          cropPair: bestCropPair,
          semanticMatch: isSemMatch,
          explanation: 'クロップ埋め込み一致 ($bestCropPair, 類似度: ${(embSim * 100).toStringAsFixed(1)}%)',
        );
      }
    }

    // Condition C: Moderate Inliers + Moderate pHash within 3 minutes
    if (diffSeconds != null && diffSeconds <= 180) {
      if (inliers >= 8 && inlierRatio >= 0.12 && pHashDist != null && pHashDist <= 18) {
        return PairSimilarityResult(
          category: PairCategory.sameSceneVariant,
          isSameScene: true,
          confidence: 0.72,
          needsReview: true,
          diffSeconds: diffSeconds,
          pHashDistance: pHashDist,
          colorDistance: colorDist,
          orbGoodMatches: goodMatches,
          orbInliers: inliers,
          orbInlierRatio: inlierRatio,
          embeddingSimilarity: embSim,
          cropPair: bestCropPair,
          semanticMatch: isSemMatch,
          explanation: '構図変化・要確認 (Inliers: $inliers点, pHash: $pHashDist)',
        );
      }
    }

    // -------------------------------------------------------------
    // Category 3: sameSubjectDifferentEvent (同じ被写体だが別イベント)
    // -------------------------------------------------------------
    // Same person/object detected or high embedding similarity, BUT different event
    final isDifferentEvent = (diffSeconds != null && diffSeconds > 600);
    if (isDifferentEvent && (isSemMatch || (embSim != null && embSim >= 0.72))) {
      return PairSimilarityResult(
        category: PairCategory.sameSubjectDifferentEvent,
        isSameScene: false, // CRITICAL: Never auto-merge for deletion!
        confidence: 0.60,
        needsReview: true,
        diffSeconds: diffSeconds,
        pHashDistance: pHashDist,
        colorDistance: colorDist,
        orbGoodMatches: goodMatches,
        orbInliers: inliers,
        orbInlierRatio: inlierRatio,
        embeddingSimilarity: embSim,
        cropPair: bestCropPair,
        semanticMatch: isSemMatch,
        explanation: '同じ被写体・別イベント (${(diffSeconds / 60).round()}分差, 削除グループ結合除外)',
      );
    }

    // If only semantic labels match (e.g. both have a 'person' or 'car') without any visual match
    if (isSemMatch && (pHashDist != null && pHashDist > 20) && inliers < 5) {
      return PairSimilarityResult(
        category: PairCategory.sameSubjectDifferentEvent,
        isSameScene: false,
        confidence: 0.40,
        needsReview: false,
        diffSeconds: diffSeconds,
        pHashDistance: pHashDist,
        colorDistance: colorDist,
        orbGoodMatches: goodMatches,
        orbInliers: inliers,
        orbInlierRatio: inlierRatio,
        embeddingSimilarity: embSim,
        cropPair: bestCropPair,
        semanticMatch: true,
        explanation: '被写体ラベル一致のみ（別構図・別イベント扱い）',
      );
    }

    // -------------------------------------------------------------
    // Category 4: different (別写真)
    // -------------------------------------------------------------
    return PairSimilarityResult(
      category: PairCategory.different,
      isSameScene: false,
      confidence: 0.0,
      needsReview: false,
      diffSeconds: diffSeconds,
      pHashDistance: pHashDist,
      colorDistance: colorDist,
      orbGoodMatches: goodMatches,
      orbInliers: inliers,
      orbInlierRatio: inlierRatio,
      embeddingSimilarity: embSim,
      cropPair: bestCropPair,
      semanticMatch: isSemMatch,
      explanation: '別写真 (類似点なし)',
    );
  }

  /// Calculates the best embedding similarity across all crop combinations.
  /// Returns (maxSimilarity, 'cropA-cropB'). If embeddings are null, returns (null, null).
  static (double?, String?) _calcBestEmbeddingSimilarity(PhotoEntry a, PhotoEntry b) {
    if (a.embeddings == null || b.embeddings == null) return (null, null);
    if (a.embeddings!.isEmpty || b.embeddings!.isEmpty) return (null, null);
    
    double maxSim = -1.0;
    String? bestPair;

    for (final entryA in a.embeddings!.entries) {
      for (final entryB in b.embeddings!.entries) {
        final sim = _cosineSimilarity(entryA.value, entryB.value);
        if (sim > maxSim) {
          maxSim = sim;
          bestPair = '${entryA.key}-${entryB.key}';
        }
      }
    }

    if (maxSim < 0.0) return (null, null);
    return (maxSim, bestPair);
  }
  
  static double _cosineSimilarity(Float32List a, Float32List b) {
    if (a.isEmpty || a.length != b.length) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA <= 0 || normB <= 0) return 0.0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  static int? _calcPHashDistance(PhotoEntry a, PhotoEntry b) {
    final ha = a.pHashHex;
    final hb = b.pHashHex;
    if (ha.isEmpty || hb.isEmpty) return null;
    if (ha == '0000000000000000' || hb == '0000000000000000') return null;
    
    final aBig = BigInt.tryParse(ha.padLeft(16, '0'), radix: 16);
    final bBig = BigInt.tryParse(hb.padLeft(16, '0'), radix: 16);
    if (aBig == null || bBig == null) return null;
    
    var x = aBig ^ bBig;
    var count = 0;
    while (x != BigInt.zero) {
      x &= (x - BigInt.one);
      count++;
    }
    return count > 64 ? 64 : count;
  }

  static double? _calcColorDistance(PhotoEntry a, PhotoEntry b) {
    final hA = a.hueHistogram;
    final hB = b.hueHistogram;
    if (hA == null || hB == null || hA.isEmpty || hB.isEmpty) {
      return null;
    }

    var sumA = 0.0;
    var sumB = 0.0;
    for (var i = 0; i < hA.length; i++) {
      sumA += hA[i];
    }
    for (var i = 0; i < hB.length; i++) {
      sumB += hB[i];
    }
    if (sumA <= 0.0001 || sumB <= 0.0001) {
      return null;
    }

    if (hA.length == hB.length) {
      double sum = 0.0;
      for (var i = 0; i < hA.length; i++) {
        sum += math.sqrt(hA[i] * hB[i]);
      }
      final val = 1.0 - sum;
      return val <= 0.0 ? 0.0 : math.sqrt(val);
    }
    return null;
  }
  
  static bool _semanticSimilar(PhotoEntry a, PhotoEntry b) {
    final ao = a.semanticObjects;
    final bo = b.semanticObjects;
    if (ao.isEmpty || bo.isEmpty) {
      // Check face presence
      if (a.portrait.hasFace && b.portrait.hasFace) {
        return true;
      }
      return false;
    }

    var matches = 0;
    for (final oa in ao) {
      for (final ob in bo) {
        if (oa.label != ob.label) continue;
        final iou = _iou(oa, ob);
        if (iou >= 0.25) {
          matches++;
          if (matches >= 1) return true;
        }
      }
    }
    return false;
  }

  static double _iou(SemanticObject a, SemanticObject b) {
    final ax1 = a.x;
    final ay1 = a.y;
    final ax2 = a.x + a.w;
    final ay2 = a.y + a.h;
    final bx1 = b.x;
    final by1 = b.y;
    final bx2 = b.x + b.w;
    final by2 = b.y + b.h;

    final ix1 = ax1 > bx1 ? ax1 : bx1;
    final iy1 = ay1 > by1 ? ay1 : by1;
    final ix2 = ax2 < bx2 ? ax2 : bx2;
    final iy2 = ay2 < by2 ? ay2 : by2;
    final iw = (ix2 - ix1);
    final ih = (iy2 - iy1);
    if (iw <= 0 || ih <= 0) return 0;
    final inter = iw * ih;
    final union = (a.w * a.h) + (b.w * b.h) - inter;
    if (union <= 0) return 0;
    return inter / union;
  }
}
