import 'dart:math' as math;
import '../../models/photo_entry.dart';
import '../../models/photo_group.dart';
import 'pair_evaluator.dart';

enum GroupingAlgorithm {
  legacy,   // Baseline implementation
  advanced, // Multi-candidate generation + PairEvaluator + Constrained Agglomerative Clustering
}

class GroupingConfig {
  const GroupingConfig({
    this.algorithm = GroupingAlgorithm.advanced,
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
    this.maxCandidatesPerPhoto = 25,
  });

  final GroupingAlgorithm algorithm;
  final int burstWindowSeconds;
  final int relaxedTimeWindowMinutes;
  final int semanticTimeWindowMinutes;
  final int maxPHashHammingDistance;
  final int semanticMinMatches;
  final double semanticMinIoU;
  final int autoDeleteKeepTopN;
  final int orbMinMatches;
  final int orbMaxHammingDist;
  final double maxColorBhattacharyyaDistance;
  final int maxDriftPHashDistance;
  final double maxDriftColorDistance;
  final int maxCandidatesPerPhoto;
}

class PhotoGrouper {
  static List<PhotoGroup> group(List<PhotoEntry> items, GroupingConfig config) {
    if (items.isEmpty) return [];

    if (config.algorithm == GroupingAlgorithm.legacy) {
      return _groupLegacy(items, config);
    } else {
      return _groupAdvanced(items, config);
    }
  }

  // =========================================================================
  // ADVANCED GROUPING: Multi-Candidate Generation + Constrained Clustering
  // =========================================================================
  static List<PhotoGroup> _groupAdvanced(List<PhotoEntry> items, GroupingConfig config) {
    // 1. Sort items chronologically
    final sorted = items.toList()
      ..sort((a, b) {
        final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ta.compareTo(tb);
      });

    final n = sorted.length;

    // 2. Multi-channel Candidate Generation
    // Union of:
    // a) Time proximity candidates
    // b) pHash nearest neighbors
    // c) Color proximity candidates
    // d) Semantic object candidates
    // e) Multi-crop embedding candidates
    final candidatePairs = <int, Set<int>>{};
    for (int i = 0; i < n; i++) {
      candidatePairs[i] = <int>{};
    }

    for (int i = 0; i < n; i++) {
      final a = sorted[i];
      final ta = a.capturedAt;

      // Scored candidate list for photo i: Map<candidateIndex, priorityScore>
      final candidateScores = <int, double>{};

      // a) Time proximity (adjacent photos or within 180 seconds)
      final timeRange = 12; // adjacent window
      final startJ = math.max(0, i - timeRange);
      final endJ = math.min(n - 1, i + timeRange);
      for (int j = startJ; j <= endJ; j++) {
        if (i == j) continue;
        final tb = sorted[j].capturedAt;
        if (ta != null && tb != null) {
          final diffSec = (ta.difference(tb).inMilliseconds.abs() / 1000.0);
          if (diffSec <= 180.0) {
            candidateScores[j] = (candidateScores[j] ?? 0.0) + math.max(0.0, 30.0 - (diffSec / 6.0));
          }
        } else {
          // If no timestamp, adjacent index proximity
          candidateScores[j] = (candidateScores[j] ?? 0.0) + 15.0;
        }
      }

      // b) pHash / Color / Semantic / Embedding over entire session
      for (int j = 0; j < n; j++) {
        if (i == j) continue;
        final b = sorted[j];

        // pHash distance
        final pDist = _calcPHashDistance(a, b);
        if (pDist != null && pDist <= 22) {
          final pScore = (24 - pDist) * 3.0; // Up to 72 pts
          candidateScores[j] = (candidateScores[j] ?? 0.0) + pScore;
        }

        // Color distance
        final cDist = _calcColorDistance(a, b);
        if (cDist != null && cDist <= 0.25) {
          candidateScores[j] = (candidateScores[j] ?? 0.0) + 20.0;
        }

        // Semantic objects
        if (a.semanticObjects.isNotEmpty && b.semanticObjects.isNotEmpty) {
          for (final oa in a.semanticObjects) {
            for (final ob in b.semanticObjects) {
              if (oa.label == ob.label) {
                candidateScores[j] = (candidateScores[j] ?? 0.0) + 25.0;
                break;
              }
            }
          }
        }

        // Embedding similarity (if available)
        if (a.embeddings != null && b.embeddings != null) {
          final (embSim, _) = _calcBestEmbeddingSimilarity(a, b);
          if (embSim != null && embSim >= 0.70) {
            candidateScores[j] = (candidateScores[j] ?? 0.0) + (embSim * 50.0);
          }
        }
      }

      // Cap to top N candidates per photo to avoid O(N^2)
      final sortedCandidates = candidateScores.keys.toList()
        ..sort((x, y) => candidateScores[y]!.compareTo(candidateScores[x]!));

      final topCandidates = sortedCandidates.take(config.maxCandidatesPerPhoto);
      for (final cand in topCandidates) {
        final minIdx = math.min(i, cand);
        final maxIdx = math.max(i, cand);
        candidatePairs[minIdx]!.add(maxIdx);
      }
    }

    // 3. Pairwise Evaluation for Selected Candidate Edges
    final edgeResults = <String, PairSimilarityResult>{};
    for (int i = 0; i < n; i++) {
      for (final j in candidatePairs[i]!) {
        final pairKey = '$i-$j';
        final revKey = '$j-$i';
        final result = PairSimilarityEvaluator.evaluate(
          sorted[i],
          sorted[j],
          burstWindowSeconds: config.burstWindowSeconds,
        );
        edgeResults[pairKey] = result;
        edgeResults[revKey] = result;
      }
    }

    // 4. Constrained Agglomerative Clustering
    // Start with each photo in its own cluster
    final clusters = <List<int>>[
      for (int i = 0; i < n; i++) [i]
    ];
    final clusterNeedsReview = <int, bool>{
      for (int i = 0; i < n; i++) i: false
    };

    while (true) {
      int bestA = -1;
      int bestB = -1;
      double bestAffinity = -1.0;
      bool bestPairNeedsReview = false;

      for (int aIdx = 0; aIdx < clusters.length; aIdx++) {
        for (int bIdx = aIdx + 1; bIdx < clusters.length; bIdx++) {
          final cA = clusters[aIdx];
          final cB = clusters[bIdx];

          // Check if there is any same-scene candidate edge between cA and cB
          var hasSameSceneEdge = false;
          var hasForbiddenEdge = false;
          double totalConfidence = 0.0;
          int connectedCount = 0;
          bool edgeNeedsReview = false;

          for (final u in cA) {
            for (final v in cB) {
              final res = edgeResults['$u-$v'];
              if (res != null) {
                if (res.category == PairCategory.sameSubjectDifferentEvent) {
                  hasForbiddenEdge = true; // Same subject but different event: NEVER merge!
                }
                if (res.isSameScene) {
                  hasSameSceneEdge = true;
                  totalConfidence += res.confidence;
                  connectedCount++;
                  if (res.needsReview) edgeNeedsReview = true;
                }
              }
            }
          }

          if (hasForbiddenEdge || !hasSameSceneEdge || connectedCount == 0) {
            continue;
          }

          // Multi-representative Verification (Check top 3 from each cluster)
          final repsA = _getRepresentatives(cA, sorted, edgeResults, 3);
          final repsB = _getRepresentatives(cB, sorted, edgeResults, 3);

          var driftViolation = false;
          for (final rA in repsA) {
            for (final rB in repsB) {
              final res = edgeResults['$rA-$rB'] ?? PairSimilarityEvaluator.evaluate(sorted[rA], sorted[rB]);
              // Extreme difference between representatives prevents chaining drift
              final pDist = res.pHashDistance ?? 64;
              final inliers = res.orbInliers ?? 0;
              if (pDist >= config.maxDriftPHashDistance && inliers < 8) {
                driftViolation = true;
                break;
              }
            }
            if (driftViolation) break;
          }

          if (driftViolation) continue;

          final avgAffinity = totalConfidence / connectedCount;
          if (avgAffinity >= 0.65 && avgAffinity > bestAffinity) {
            bestAffinity = avgAffinity;
            bestA = aIdx;
            bestB = bIdx;
            bestPairNeedsReview = edgeNeedsReview;
          }
        }
      }

      if (bestA != -1 && bestB != -1) {
        // Merge cluster B into cluster A
        clusters[bestA].addAll(clusters[bestB]);
        if (bestPairNeedsReview || (clusterNeedsReview[bestB] ?? false)) {
          clusterNeedsReview[bestA] = true;
        }
        clusters.removeAt(bestB);
      } else {
        break; // No more valid merges
      }
    }

    // 5. Cluster Refinement & Post-Validation (Outlier Separation)
    final refinedClusters = <List<int>>[];
    final refinedNeedsReview = <bool>[];

    for (int cIdx = 0; cIdx < clusters.length; cIdx++) {
      final cluster = clusters[cIdx];
      if (cluster.length <= 1) {
        refinedClusters.add(cluster);
        refinedNeedsReview.add(clusterNeedsReview[cIdx] ?? false);
        continue;
      }

      final validMembers = <int>[];
      final outliers = <int>[];

      for (final member in cluster) {
        // Must have at least one strong link (>= 0.60) to another member in the cluster
        bool hasSupport = false;
        for (final other in cluster) {
          if (member == other) continue;
          final res = edgeResults['$member-$other'] ?? PairSimilarityEvaluator.evaluate(sorted[member], sorted[other]);
          if (res.isSameScene && res.confidence >= 0.60) {
            hasSupport = true;
            break;
          }
        }
        if (hasSupport) {
          validMembers.add(member);
        } else {
          outliers.add(member);
        }
      }

      if (validMembers.isNotEmpty) {
        refinedClusters.add(validMembers);
        refinedNeedsReview.add(clusterNeedsReview[cIdx] ?? false);
      }
      for (final out in outliers) {
        refinedClusters.add([out]);
        refinedNeedsReview.add(false);
      }
    }

    // 6. Build PhotoGroup objects and evaluate Best shots
    final groups = <PhotoGroup>[];
    var groupIdCounter = 1;

    for (int i = 0; i < refinedClusters.length; i++) {
      final clusterIndices = refinedClusters[i];
      final isGroupNeedsReview = refinedNeedsReview[i];
      final groupItems = <PhotoEntry>[];

      if (clusterIndices.length == 1) {
        final entry = sorted[clusterIndices[0]];
        groupItems.add(
          entry.copyWith(
            groupExplanation: () => const GroupMatchExplanation(
              matchType: '単独',
              description: '類似写真なし',
              confidence: 1.0,
            ),
          ),
        );
      } else {
        // Find Anchor (best representative)
        final anchor = _getRepresentatives(clusterIndices, sorted, edgeResults, 1).first;
        final anchorEntry = sorted[anchor];

        for (final idx in clusterIndices) {
          final item = sorted[idx];
          if (idx == anchor) {
            groupItems.add(
              item.copyWith(
                groupExplanation: () => const GroupMatchExplanation(
                  matchType: '代表カット',
                  description: 'グループの基準写真',
                  confidence: 1.0,
                ),
              ),
            );
          } else {
            final res = edgeResults['$anchor-$idx'] ?? PairSimilarityEvaluator.evaluate(anchorEntry, item);
            groupItems.add(
              item.copyWith(
                groupExplanation: () => GroupMatchExplanation(
                  matchType: res.category == PairCategory.sameBurst ? '連写結合' : '特徴点救済マージ',
                  description: res.explanation,
                  category: res.category.name,
                  diffSeconds: res.diffSeconds,
                  pHashDistance: res.pHashDistance,
                  colorDistance: res.colorDistance,
                  orbMatches: res.orbGoodMatches,
                  inliers: res.orbInliers,
                  orbInlierRatio: res.orbInlierRatio,
                  embeddingSimilarity: res.embeddingSimilarity,
                  cropPair: res.cropPair,
                  semanticMatch: res.semanticMatch,
                  confidence: res.confidence,
                  needsReview: res.needsReview,
                  referenceKey: anchorEntry.key,
                ),
              ),
            );
          }
        }
      }

      final isBurstGroup = _isBurstGroup(groupItems, config.burstWindowSeconds);
      _reorderAndMarkBest(groupItems, isBurstGroup, config);
      final best = groupItems.first;

      // Auto-deletion selection:
      // Safety Rule: If group is needsReview, do NOT mark delete candidates automatically!
      final deleteCandidates = <String>{};
      if (!isGroupNeedsReview && groupItems.length > config.autoDeleteKeepTopN) {
        for (int k = config.autoDeleteKeepTopN; k < groupItems.length; k++) {
          final item = groupItems[k];
          // Never auto-delete items flagged for review
          if (item.groupExplanation?.needsReview != true) {
            deleteCandidates.add(item.key);
          }
        }
      }

      groups.add(
        PhotoGroup(
          id: 'G${groupIdCounter++}',
          items: groupItems,
          bestKey: best.key,
          deleteCandidateKeys: deleteCandidates,
          isBurst: isBurstGroup,
          needsReview: isGroupNeedsReview,
        ),
      );
    }

    // 7. Sort groups chronologically
    groups.sort((a, b) {
      final ta = a.items
          .map((e) => e.capturedAt)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (min, t) => min == null || t.isBefore(min) ? t : min);
      final tb = b.items
          .map((e) => e.capturedAt)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (min, t) => min == null || t.isBefore(min) ? t : min);

      return ta == null && tb == null ? 0 : ta == null ? 1 : tb == null ? -1 : ta.compareTo(tb);
    });

    return groups;
  }

  static List<int> _getRepresentatives(
    List<int> cluster,
    List<PhotoEntry> sorted,
    Map<String, PairSimilarityResult> edgeResults,
    int topK,
  ) {
    if (cluster.length <= topK) return cluster;

    // Score by sharpness and centrality
    final scores = <int, double>{};
    for (final idx in cluster) {
      final entry = sorted[idx];
      var score = entry.sharpness;
      for (final other in cluster) {
        if (idx != other) {
          score += (edgeResults['$idx-$other']?.confidence ?? 0.0) * 100.0;
        }
      }
      scores[idx] = score;
    }

    final sortedList = cluster.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    return sortedList.take(topK).toList();
  }

  // =========================================================================
  // LEGACY GROUPING (Baseline Reference Implementation)
  // =========================================================================
  static List<PhotoGroup> _groupLegacy(List<PhotoEntry> items, GroupingConfig config) {
    final sorted = items.toList()
      ..sort((a, b) {
        final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ta.compareTo(tb);
      });

    final parent = List<int>.generate(sorted.length, (i) => i);
    int find(int i) {
      if (parent[i] == i) return i;
      return parent[i] = find(parent[i]);
    }
    void union(int i, int j) {
      final rootI = find(i);
      final rootJ = find(j);
      if (rootI != rootJ) parent[rootI] = rootJ;
    }

    for (int i = 0; i < sorted.length; i++) {
      for (int j = i + 1; j < sorted.length; j++) {
        final a = sorted[i];
        final b = sorted[j];
        final ta = a.capturedAt;
        final tb = b.capturedAt;

        if (ta != null && tb != null) {
          final diffSec = (ta.difference(tb).inMilliseconds.abs() / 1000.0);
          final pDist = _calcPHashDistance(a, b);
          if (diffSec <= config.burstWindowSeconds && (pDist == null || pDist <= config.maxPHashHammingDistance)) {
            union(i, j);
          }
        }
      }
    }

    final clusterMap = <int, List<PhotoEntry>>{};
    for (int i = 0; i < sorted.length; i++) {
      final root = find(i);
      clusterMap.putIfAbsent(root, () => []).add(sorted[i]);
    }

    final groups = <PhotoGroup>[];
    var idCounter = 1;
    for (final groupItems in clusterMap.values) {
      final isBurst = _isBurstGroup(groupItems, config.burstWindowSeconds);
      _reorderAndMarkBest(groupItems, isBurst, config);
      groups.add(
        PhotoGroup(
          id: 'LEGACY_G${idCounter++}',
          items: groupItems,
          bestKey: groupItems.first.key,
          deleteCandidateKeys: groupItems.skip(config.autoDeleteKeepTopN).map((e) => e.key).toSet(),
          isBurst: isBurst,
          needsReview: false,
        ),
      );
    }
    return groups;
  }

  // =========================================================================
  // HELPER UTILITIES
  // =========================================================================
  static (double?, String?) _calcBestEmbeddingSimilarity(PhotoEntry a, PhotoEntry b) {
    if (a.embeddings == null || b.embeddings == null) return (null, null);
    if (a.embeddings!.isEmpty || b.embeddings!.isEmpty) return (null, null);

    double maxSim = -1.0;
    String? bestPair;
    for (final ea in a.embeddings!.entries) {
      for (final eb in b.embeddings!.entries) {
        final sim = _cosineSimilarity(ea.value, eb.value);
        if (sim > maxSim) {
          maxSim = sim;
          bestPair = '${ea.key}-${eb.key}';
        }
      }
    }
    if (maxSim < 0) return (null, null);
    return (maxSim, bestPair);
  }

  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || a.length != b.length) return 0.0;
    double dot = 0.0, normA = 0.0, normB = 0.0;
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
    if (ha.isEmpty || hb.isEmpty || ha == '0000000000000000' || hb == '0000000000000000') return null;
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
    if (hA == null || hB == null || hA.isEmpty || hB.isEmpty) return null;

    var sumA = 0.0, sumB = 0.0;
    for (var i = 0; i < hA.length; i++) {
      sumA += hA[i];
    }
    for (var i = 0; i < hB.length; i++) {
      sumB += hB[i];
    }
    if (sumA <= 0.0001 || sumB <= 0.0001) return null;

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

  static bool _isBurstGroup(List<PhotoEntry> items, int burstWindowSeconds) {
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.length < 2) return false;
    final span = times.last.difference(times.first).inSeconds.abs();
    return span <= burstWindowSeconds;
  }

  static int? _parseIso(String? iso) {
    if (iso == null) return null;
    final m = RegExp(r'\d+').firstMatch(iso);
    if (m != null) return int.tryParse(m.group(0)!);
    return null;
  }

  static void _reorderAndMarkBest(
    List<PhotoEntry> items,
    bool isBurst,
    GroupingConfig config,
  ) {
    if (items.isEmpty) return;

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
        formula = '顔(${f.toStringAsFixed(2)})×60% + ピント(${s.toStringAsFixed(2)})×35% + 露出(${x.toStringAsFixed(2)})×5% = ${(total * 100).toStringAsFixed(1)}点';
      } else {
        total = (s * 0.8) + (x * 0.2);
        rule = '一般シーン（ピント80%＋露出20%）';
        formula = 'ピント(${s.toStringAsFixed(2)})×80% + 露出(${x.toStringAsFixed(2)})×20% = ${(total * 100).toStringAsFixed(1)}点';
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

    updated.sort((a, b) => (b.scoreExplanation?.totalScore ?? 0).compareTo(a.scoreExplanation?.totalScore ?? 0));

    items.clear();
    items.addAll(updated);
  }
}
