import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/photo_entry.dart';
import '../../models/photo_group.dart';

class GroupingConfig {
  const GroupingConfig({
    this.burstWindowSeconds = 15,
    this.relaxedTimeWindowMinutes = 1,
    this.semanticTimeWindowMinutes = 3,
    this.maxPHashHammingDistance = 14,
    this.semanticMinMatches = 2,
    this.semanticMinIoU = 0.4,
    this.autoDeleteKeepTopN = 1,
    this.orbMinMatches = 30,
    this.orbMaxHammingDist = 45,
    this.maxColorBhattacharyyaDistance = 0.50,
    this.maxDriftPHashDistance = 18,
    this.maxDriftColorDistance = 0.40,
  });

  /// Window in seconds for considering nearby photos as a single shooting event.
  final int burstWindowSeconds;

  /// Window in minutes for relaxed grouping of very similar compositions.
  final int relaxedTimeWindowMinutes;

  /// Semantic grouping window (minutes) when ML Kit results are available.
  final int semanticTimeWindowMinutes;

  /// pHash is 64-bit. Higher is looser.
  final int maxPHashHammingDistance;

  /// Minimum matched objects (label+IoU) to consider same subject.
  final int semanticMinMatches;

  /// Minimum IoU for bounding box match.
  final double semanticMinIoU;

  /// For each group, keep top N by sharpness, others become delete candidates.
  final int autoDeleteKeepTopN;

  /// Minimum ORB feature matches to consider same scene.
  final int orbMinMatches;

  /// Hamming distance threshold for ORB features (0..256).
  final int orbMaxHammingDist;

  /// Maximum color distance (Bhattacharyya distance) allowed between photos (0..1).
  /// If the distance is higher than this, they are considered to be different colors.
  final double maxColorBhattacharyyaDistance;

  /// Maximum pHash distance allowed between any item in a group and its group anchor.
  /// Prevents transitive chaining/drift where A-B-C-D... drift into completely different scenes.
  final int maxDriftPHashDistance;

  /// Maximum color distance allowed between any item in a group and its group anchor.
  final double maxDriftColorDistance;
}

class PhotoGrouper {
  static List<PhotoGroup> group(List<PhotoEntry> items, GroupingConfig config) {
    if (items.isEmpty) return [];

    // 1. Sort items by time to establish a chronological sequence.
    final sorted = items.toList()
      ..sort((a, b) {
        final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ta.compareTo(tb);
      });

    // 2. Sequential Adaptive Clustering with Anchor Drift Control (Prevents Transitive Chaining).
    final clusters = <List<PhotoEntry>>[];
    for (final entry in sorted) {
      if (clusters.isEmpty) {
        final anchorEntry = entry.copyWith(
          groupExplanation: () => const GroupMatchExplanation(
            matchType: '起点カット',
            description: 'グループの起点（基準写真）',
          ),
        );
        clusters.add([anchorEntry]);
        continue;
      }

      final currentCluster = clusters.last;
      final (canAdd, exp) = _checkAddToCluster(currentCluster, entry, config);
      if (canAdd) {
        final matchedEntry = entry.copyWith(groupExplanation: () => exp);
        currentCluster.add(matchedEntry);
      } else {
        final newAnchor = entry.copyWith(
          groupExplanation: () => const GroupMatchExplanation(
            matchType: '起点カット',
            description: 'グループの起点（基準写真）',
          ),
        );
        clusters.add([newAnchor]);
      }
    }

    // 3. Post-merge: Safe merging of non-adjacent clusters with identical composition (e.g. tripod re-shots).
    final mergedClusters = _postMergeClusters(clusters, config);

    // 4. Generate PhotoGroup objects and evaluate Best shots.
    final groups = <PhotoGroup>[];
    var groupIdCounter = 1;

    for (final groupItems in mergedClusters) {
      final isBurstGroup = _isBurstGroup(groupItems, config.burstWindowSeconds);

      // Best selection:
      _reorderAndMarkBest(groupItems, isBurstGroup, config);
      final best = groupItems.first;
      final deleteCandidates = <String>{};

      groups.add(
        PhotoGroup(
          id: 'G${groupIdCounter++}',
          items: groupItems,
          bestKey: best.key,
          deleteCandidateKeys: deleteCandidates,
          isBurst: isBurstGroup,
        ),
      );
    }

    // 5. Sort groups by the earliest capturedAt time in each group (ascending).
    groups.sort((a, b) {
      final ta = a.items
          .map((e) => e.capturedAt)
          .whereType<DateTime>()
          .fold<DateTime?>(
            null,
            (min, t) => min == null || t.isBefore(min) ? t : min,
          );
      final tb = b.items
          .map((e) => e.capturedAt)
          .whereType<DateTime>()
          .fold<DateTime?>(
            null,
            (min, t) => min == null || t.isBefore(min) ? t : min,
          );

      return ta == null && tb == null
          ? 0
          : ta == null
          ? 1
          : tb == null
          ? -1
          : ta.compareTo(tb);
    });

    return groups;
  }

  /// Checks if [candidate] can be added to [cluster] without causing transitive chaining drift.
  static (bool, GroupMatchExplanation?) _checkAddToCluster(
    List<PhotoEntry> cluster,
    PhotoEntry candidate,
    GroupingConfig config,
  ) {
    if (cluster.isEmpty) {
      return (
        true,
        const GroupMatchExplanation(
          matchType: '起点カット',
          description: 'グループ起点カット',
        )
      );
    }

    // Condition 1: Must be similar to the immediately preceding frame in the cluster.
    final last = cluster.last;
    final (isSim, matchExp) = _checkSimilar(last, candidate, config);
    if (!isSim) {
      return (false, null);
    }

    // Condition 2: Anti-drift check against the cluster anchor (first frame).
    // Prevents gradual drift where frame 1 is completely different from frame 20.
    final anchor = cluster.first;

    // Check color drift
    final colorDist = _calcColorDistance(anchor, candidate);
    if (colorDist != null && colorDist > config.maxDriftColorDistance) {
      return (false, null);
    }

    // Check pHash drift
    final pHashDist = _calcPHashDistance(anchor, candidate);
    if (pHashDist != null && pHashDist > config.maxDriftPHashDistance) {
      return (false, null);
    }

    return (true, matchExp);
  }

  /// Merges separated clusters that share an identical scene/composition (e.g. tripod shots taken 30s apart).
  static List<List<PhotoEntry>> _postMergeClusters(
    List<List<PhotoEntry>> clusters,
    GroupingConfig config,
  ) {
    if (clusters.length <= 1) return clusters;

    final result = <List<PhotoEntry>>[];
    final merged = List<bool>.filled(clusters.length, false);

    for (var i = 0; i < clusters.length; i++) {
      if (merged[i]) continue;
      final current = clusters[i].toList();

      for (var j = i + 1; j < clusters.length; j++) {
        if (merged[j]) continue;
        final target = clusters[j];

        // Only compare clusters within a reasonable time window (e.g. 3 minutes).
        final ta = current.last.capturedAt;
        final tb = target.first.capturedAt;
        if (ta != null && tb != null && tb.difference(ta).inMinutes.abs() > 3) {
          continue;
        }

        // Strict identical composition check between representative frames
        final (isIdentical, mergeExp) = _checkClustersIdenticalScene(
          current,
          target,
          config,
        );
        if (isIdentical) {
          for (final tItem in target) {
            current.add(tItem.copyWith(groupExplanation: () => mergeExp));
          }
          merged[j] = true;
        }
      }
      result.add(current);
    }

    return result;
  }

  static (bool, GroupMatchExplanation?) _checkClustersIdenticalScene(
    List<PhotoEntry> c1,
    List<PhotoEntry> c2,
    GroupingConfig config,
  ) {
    final rep1 = c1.first;
    final rep2 = c2.first;

    final colorDist = _calcColorDistance(rep1, rep2);
    final pDist = _calcPHashDistance(rep1, rep2);
    final orbMatches = _countOrbMatches(rep1, rep2, config.orbMaxHammingDist);

    final ta = rep1.capturedAt;
    final tb = rep2.capturedAt;
    final double? diffSec = (ta != null && tb != null)
        ? (tb.difference(ta).inMilliseconds.abs() / 1000.0)
        : null;

    // 1. ORB一致が強力な場合 (>= 25): ズーム比率や画角変更で背景色分布が変化(colorDist <= 0.75)しても
    // 被写体の特徴点が確実に一致していれば同一被写体・構図として救済結合する。
    if (orbMatches >= 25 && (colorDist == null || colorDist <= 0.75)) {
      return (
        true,
        GroupMatchExplanation(
          matchType: '特徴点救済マージ',
          description:
              'ズーム/画角撮り直し: ORB $orbMatches点一致 (色距離: ${colorDist?.toStringAsFixed(3) ?? "-"})',
          diffSeconds: diffSec,
          pHashDistance: pDist,
          colorDistance: colorDist,
          orbMatches: orbMatches,
          referenceKey: rep1.key,
        )
      );
    }

    // 2. 色差が明確に離れている場合は原則除外 (0.30)
    if (colorDist != null && colorDist > 0.30) {
      return (false, null);
    }

    // 3. Strict pHash check (<= 8)
    if (pDist != null && pDist <= 8) {
      return (
        true,
        GroupMatchExplanation(
          matchType: '三脚構図マージ',
          description: '同一構図: pHash距離 $pDist <= 8',
          diffSeconds: diffSec,
          pHashDistance: pDist,
          colorDistance: colorDist,
          orbMatches: orbMatches,
          referenceKey: rep1.key,
        )
      );
    }

    // 4. Strict ORB match (>= 40)
    if (orbMatches >= 40) {
      return (
        true,
        GroupMatchExplanation(
          matchType: '高精度特徴点マージ',
          description: '同一構図: ORB $orbMatches点一致 >= 40',
          diffSeconds: diffSec,
          pHashDistance: pDist,
          colorDistance: colorDist,
          orbMatches: orbMatches,
          referenceKey: rep1.key,
        )
      );
    }

    return (false, null);
  }

  static int? _parseIso(String? iso) {
    if (iso == null) return null;
    final m = RegExp(r'\d+').firstMatch(iso);
    if (m != null) {
      return int.tryParse(m.group(0)!);
    }
    return null;
  }

  static void _reorderAndMarkBest(
    List<PhotoEntry> items,
    bool isBurst,
    GroupingConfig config,
  ) {
    if (items.isEmpty) return;

    // Find max effective sharpness in this group for normalization.
    var maxEffectiveSharp = 0.01;
    for (final e in items) {
      final iso = _parseIso(e.exif?.iso);
      var eff = e.sharpness;
      if (iso != null && iso > 800) {
        eff = e.sharpness / (1.0 + (iso - 800) * 0.00015);
      }
      if (eff > maxEffectiveSharp) maxEffectiveSharp = eff;
    }

    final updated = <PhotoEntry>[];
    for (final e in items) {
      final iso = _parseIso(e.exif?.iso);
      var eff = e.sharpness;
      if (iso != null && iso > 800) {
        eff = e.sharpness / (1.0 + (iso - 800) * 0.00015);
      }

      // Normalize effective sharpness within this group (0..1).
      final s = (eff / maxEffectiveSharp).clamp(0.0, 1.0);
      final x = e.exposureScore.clamp(0.0, 1.0);
      final f = e.faceQualityScore.clamp(0.0, 1.0);

      double total;
      String rule;
      String formula;

      if (isBurst) {
        total = s;
        rule = '連写判定（ピント最重視）';
        formula = 'ピント正規化(${s.toStringAsFixed(2)}) = ${(total * 100).toStringAsFixed(1)}点';
      } else if (f > 0) {
        total = (f * 0.6) + (s * 0.35) + (x * 0.05);
        rule = 'ポートレート（顔・表情重視）';
        formula =
            '顔(${f.toStringAsFixed(2)})×60% + ピント(${s.toStringAsFixed(2)})×35% + 露出(${x.toStringAsFixed(2)})×5% = ${(total * 100).toStringAsFixed(1)}点';
      } else {
        total = (s * 0.8) + (x * 0.2);
        rule = '一般シーン（ピント80%＋露出20%）';
        formula =
            'ピント(${s.toStringAsFixed(2)})×80% + 露出(${x.toStringAsFixed(2)})×20% = ${(total * 100).toStringAsFixed(1)}点';
      }

      final exp = ScoreExplanation(
        totalScore: total,
        rawSharpness: e.sharpness,
        effectiveSharpness: eff,
        normalizedSharpness: s,
        exposureScore: x,
        faceQualityScore: f,
        ruleName: rule,
        formulaText: formula,
      );

      updated.add(e.copyWith(scoreExplanation: () => exp));
    }

    updated.sort(
      (a, b) => (b.scoreExplanation?.totalScore ?? 0).compareTo(
        a.scoreExplanation?.totalScore ?? 0,
      ),
    );

    items.clear();
    items.addAll(updated);
  }

  static int? _calcPHashDistance(PhotoEntry a, PhotoEntry b) {
    final ha = a.pHashHex;
    final hb = b.pHashHex;
    if (ha.isEmpty || hb.isEmpty) return null;
    if (ha == '0000000000000000' || hb == '0000000000000000') return null;
    return _hammingDistance64Hex(ha, hb);
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

    return _bhattacharyyaDistance(hA, hB);
  }

  static (bool, GroupMatchExplanation?) _checkSimilar(
    PhotoEntry a,
    PhotoEntry b,
    GroupingConfig config,
  ) {
    // 0) Color similarity check: if color distance is too large, they are not similar
    final colorDist = _calcColorDistance(a, b);
    if (colorDist != null && colorDist > config.maxColorBhattacharyyaDistance) {
      return (false, null);
    }

    final ta = a.capturedAt;
    final tb = b.capturedAt;

    // Time difference in seconds (if both have EXIF timestamp)
    final double? diffSeconds = (ta != null && tb != null)
        ? (ta.difference(tb).inMilliseconds.abs() / 1000.0)
        : null;

    final pHashDist = _calcPHashDistance(a, b);

    // Fast reject: if pHash is completely different (> 28), they cannot be similar
    if (pHashDist != null && pHashDist > 28) {
      return (false, null);
    }

    final orbMatches = _countOrbMatches(a, b, config.orbMaxHammingDist);

    // 1) 超近接連写 (Δt <= 1.5秒): ハードウェア連写・連続シャッター
    if (diffSeconds != null && diffSeconds <= 1.5) {
      if (pHashDist != null && pHashDist <= 22) {
        return (
          true,
          GroupMatchExplanation(
            matchType: '超近接連写',
            description:
                'Δt: ${diffSeconds.toStringAsFixed(1)}s (シャッター連続, pHash距離: $pHashDist)',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      if (orbMatches >= 15) {
        return (
          true,
          GroupMatchExplanation(
            matchType: '超近接連写・特徴点一致',
            description:
                'Δt: ${diffSeconds.toStringAsFixed(1)}s, ORB特徴点 $orbMatches点一致',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      // pHashやORBが未計算・空でも、色差が十分近ければ同一連写として認める
      if (pHashDist == null && a.orbBytes.isEmpty) {
        return (
          true,
          GroupMatchExplanation(
            matchType: '超近接連写 (メタデータ)',
            description: 'Δt: ${diffSeconds.toStringAsFixed(1)}s (撮影時刻連続)',
            diffSeconds: diffSeconds,
            referenceKey: a.key,
          )
        );
      }
      return (false, null);
    }

    // 2) 同一バースト窓内 (1.5秒 < Δt <= burstWindowSeconds、通常15秒)
    if (diffSeconds != null && diffSeconds <= config.burstWindowSeconds) {
      if (pHashDist != null && pHashDist <= config.maxPHashHammingDistance) {
        return (
          true,
          GroupMatchExplanation(
            matchType: 'バースト構図一致',
            description:
                'Δt: ${diffSeconds.toStringAsFixed(1)}s, pHash距離 $pHashDist <= ${config.maxPHashHammingDistance}',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      if (orbMatches >= 25) {
        return (
          true,
          GroupMatchExplanation(
            matchType: 'バースト特徴点一致',
            description:
                'Δt: ${diffSeconds.toStringAsFixed(1)}s, ORB一致 $orbMatches点 >= 25',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      if (_semanticSimilar(a, b, config)) {
        return (
          true,
          GroupMatchExplanation(
            matchType: 'バースト被写体一致',
            description: 'Δt: ${diffSeconds.toStringAsFixed(1)}s, AI物体検出IoU一致',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      return (false, null);
    }

    // 3) 中間時間窓 (burstWindowSeconds < Δt <= 60秒)
    if (diffSeconds != null && diffSeconds <= 60) {
      if (pHashDist != null && pHashDist <= 10) {
        return (
          true,
          GroupMatchExplanation(
            matchType: '撮り直し構図一致',
            description:
                'Δt: ${diffSeconds.toStringAsFixed(1)}s, pHash距離 $pHashDist <= 10',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      if (orbMatches >= 35) {
        return (
          true,
          GroupMatchExplanation(
            matchType: '撮り直し特徴点一致',
            description:
                'Δt: ${diffSeconds.toStringAsFixed(1)}s, ORB一致 $orbMatches点 >= 35',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      if (_semanticSimilar(a, b, config)) {
        return (
          true,
          GroupMatchExplanation(
            matchType: '撮り直し被写体一致',
            description: 'Δt: ${diffSeconds.toStringAsFixed(1)}s, AI物体検出IoU一致',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      return (false, null);
    }

    // 4) 長期時間窓 (60秒 < Δt <= relaxedTimeWindowMinutes * 60) または 時刻情報なし
    if (diffSeconds == null ||
        diffSeconds <= config.relaxedTimeWindowMinutes * 60) {
      if (pHashDist != null && pHashDist <= 6) {
        return (
          true,
          GroupMatchExplanation(
            matchType: '三脚・完全構図一致',
            description:
                'Δt: ${diffSeconds != null ? "${diffSeconds.toStringAsFixed(1)}s" : "なし"}, pHash距離 $pHashDist <= 6',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
      if (_semanticSimilar(a, b, config)) {
        return (
          true,
          GroupMatchExplanation(
            matchType: 'AI被写体一致',
            description: 'AI物体検出IoU一致',
            diffSeconds: diffSeconds,
            pHashDistance: pHashDist,
            colorDistance: colorDist,
            orbMatches: orbMatches,
            referenceKey: a.key,
          )
        );
      }
    }

    return (false, null);
  }

  static int _countOrbMatches(
    PhotoEntry a,
    PhotoEntry b,
    int maxHammingDist,
  ) {
    if (a.orbRows == 0 || b.orbRows == 0) return 0;
    if (a.orbBytes.isEmpty || b.orbBytes.isEmpty) return 0;

    var matches = 0;
    final rA = a.orbRows > 150 ? 150 : a.orbRows;
    final rB = b.orbRows > 150 ? 150 : b.orbRows;
    final bytesA = a.orbBytes;
    final bytesB = b.orbBytes;

    for (var i = 0; i < rA; i++) {
      var bestDist = 256;
      final startA = i * 32;

      for (var j = 0; j < rB; j++) {
        final startB = j * 32;
        var dist = 0;
        for (var k = 0; k < 32; k++) {
          var x = bytesA[startA + k] ^ bytesB[startB + k];
          while (x != 0) {
            x &= (x - 1);
            dist++;
          }
          if (dist >= bestDist) break;
        }
        if (dist < bestDist) {
          bestDist = dist;
        }
        if (bestDist <= maxHammingDist) break;
      }

      if (bestDist <= maxHammingDist) {
        matches++;
      }
    }

    return matches;
  }

  static bool _semanticSimilar(
    PhotoEntry a,
    PhotoEntry b,
    GroupingConfig config,
  ) {
    final ao = a.semanticObjects;
    final bo = b.semanticObjects;
    if (ao.isEmpty || bo.isEmpty) return false;

    var matches = 0;
    for (final oa in ao) {
      for (final ob in bo) {
        if (oa.label != ob.label) continue;
        final iou = _iou(oa, ob);
        if (iou >= config.semanticMinIoU) {
          matches++;
          if (matches >= config.semanticMinMatches) return true;
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

  static bool _isBurstGroup(List<PhotoEntry> items, int burstWindowSeconds) {
    // Burst group if at least 2 photos have times within [burstWindowSeconds] range.
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()
      ..sort();
    if (times.length < 2) return false;
    final span = times.last.difference(times.first).inSeconds.abs();
    return span <= burstWindowSeconds;
  }

  static int _hammingDistance64Hex(String hexA, String hexB) {
    final a = BigInt.parse(hexA.padLeft(16, '0'), radix: 16);
    final b = BigInt.parse(hexB.padLeft(16, '0'), radix: 16);
    var x = a ^ b;
    var count = 0;
    while (x != BigInt.zero) {
      x &= (x - BigInt.one);
      count++;
    }
    return count > 64 ? 64 : count;
  }

  static double _bhattacharyyaDistance(Float32List h1, Float32List h2) {
    if (h1.length != h2.length || h1.isEmpty) return 1.0;

    // Backward compatibility for 1D Hue histograms (180 elements)
    if (h1.length == 180) {
      double sum = 0.0;
      for (var i = 0; i < 180; i++) {
        sum += math.sqrt(h1[i] * h2[i]);
      }
      final val = 1.0 - sum;
      return val <= 0.0 ? 0.0 : math.sqrt(val);
    }

    // Combined H-S-V histograms (180 + 256 + 256 = 692 elements)
    if (h1.length == 692) {
      double calcSubDist(int start, int length) {
        double sum = 0.0;
        for (var i = 0; i < length; i++) {
          sum += math.sqrt(h1[start + i] * h2[start + i]);
        }
        final val = 1.0 - sum;
        return val <= 0.0 ? 0.0 : math.sqrt(val);
      }

      final distH = calcSubDist(0, 180);
      final distS = calcSubDist(180, 256);
      final distV = calcSubDist(180 + 256, 256);

      // Calculate mean saturation (S) for both images to adjust Hue weight adaptively.
      // If one of the images is grayscale/low-saturation, Hue becomes unreliable noise.
      double calcMeanS(Float32List h) {
        double sumS = 0.0;
        double sumW = 0.0;
        for (var i = 0; i < 256; i++) {
          final w = h[180 + i];
          sumS += i * w;
          sumW += w;
        }
        return sumW > 0 ? (sumS / sumW) : 0.0;
      }

      final meanS1 = calcMeanS(h1);
      final meanS2 = calcMeanS(h2);
      final minMeanS = math.min(meanS1, meanS2);

      // Adaptive weights:
      // High saturation -> Hue is king (0.95 weight)
      // Low saturation -> Hue is noise, rely entirely on Saturation and Value (0.50 each)
      double wH, wS, wV;
      if (minMeanS >= 50.0) {
        wH = 0.95;
        wS = 0.03;
        wV = 0.02;
      } else if (minMeanS <= 15.0) {
        wH = 0.0;
        wS = 0.50;
        wV = 0.50;
      } else {
        // Linearly interpolate weights between minMeanS=15.0 and 50.0
        final ratio = ((minMeanS - 15.0) / (50.0 - 15.0)).clamp(0.0, 1.0);
        wH = 0.95 * ratio;
        wS = 0.50 - 0.47 * ratio;
        wV = 0.50 - 0.48 * ratio;
      }

      return wH * distH + wS * distS + wV * distV;
    }

    // Default fallback for any other lengths
    double sum = 0.0;
    for (var i = 0; i < h1.length; i++) {
      sum += math.sqrt(h1[i] * h2[i]);
    }
    final val = 1.0 - sum;
    return val <= 0.0 ? 0.0 : math.sqrt(val);
  }
}
