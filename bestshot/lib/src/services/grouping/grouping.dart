import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import '../../models/photo_entry.dart';
import '../../models/photo_group.dart';
import 'pair_evaluator.dart';
import '../analysis/analysis_types.dart';
import 'temporal_candidate_index.dart';

enum GroupingAlgorithm {
  legacy, // Baseline implementation
  advanced, // Multi-candidate generation + PairEvaluator + Constrained Agglomerative Clustering
}

class GroupingConfig {
  const GroupingConfig({
    this.algorithm = GroupingAlgorithm.advanced,
    this.mode = DetectionMode.standard,
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
    this.maxDriftPHashDistance = 26,
    this.maxDriftColorDistance = 0.40,
    this.maxCandidatesPerPhoto = 30,
  });

  final GroupingAlgorithm algorithm;
  final DetectionMode mode;
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
  /// Asynchronously groups [items] in a background isolate to avoid blocking the UI thread.
  /// Strips large displayBytes thumbnails before isolate boundary to reduce transfer cost from 100+ MB to <2 MB.
  static Future<List<PhotoGroup>> groupAsync(
    List<PhotoEntry> items,
    GroupingConfig config,
  ) async {
    if (items.isEmpty) return [];

    // Map original entries by key to restore full displayBytes after grouping
    final itemMap = {for (final item in items) item.key: item};

    // Strip bulky displayBytes before sending across isolate boundary
    final lightItems = items
        .map((e) => e.copyWith(displayBytes: Uint8List(0)))
        .toList();

    final lightGroups = await Isolate.run(() => group(lightItems, config));

    // Restore original entries with displayBytes while preserving groupExplanation and scoreExplanation
    return lightGroups.map((g) {
      final restoredItems = g.items.map((e) {
        final original = itemMap[e.key];
        if (original != null && original.displayBytes.isNotEmpty) {
          return e.copyWith(displayBytes: original.displayBytes);
        }
        return e;
      }).toList();
      return g.copyWith(items: restoredItems);
    }).toList();
  }

  static List<PhotoGroup> group(List<PhotoEntry> items, GroupingConfig config) {
    if (items.isEmpty) return [];
    if (items.map((item) => item.key).toSet().length != items.length) {
      throw ArgumentError('Photo keys must be unique');
    }
    if (config.maxCandidatesPerPhoto < 1 ||
        config.autoDeleteKeepTopN < 1 ||
        config.burstWindowSeconds < 0) {
      throw ArgumentError('Invalid grouping limits');
    }

    if (config.algorithm == GroupingAlgorithm.legacy) {
      return _groupLegacy(items, config);
    } else {
      return _groupAdvanced(items, config);
    }
  }

  // =========================================================================
  // ADVANCED GROUPING: Multi-Candidate Generation + Constrained Clustering
  // =========================================================================
  static List<PhotoGroup> _groupAdvanced(
    List<PhotoEntry> items,
    GroupingConfig config,
  ) {
    // 1. Sort items chronologically (with key as stable tie-breaker)
    final sorted = items.toList()
      ..sort((a, b) {
        final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final cmp = ta.compareTo(tb);
        if (cmp != 0) return cmp;
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });

    final n = sorted.length;
    final portraitMode = config.mode == DetectionMode.portrait;
    final temporalIndex = TemporalCandidateIndex(sorted);

    // Standard mode avoids expensive visual scans of unrelated sessions.
    bool eligible(int i, int j) {
      if (portraitMode) return true;
      final ta = sorted[i].capturedAt;
      final tb = sorted[j].capturedAt;
      return ta == null ||
          tb == null ||
          ta.difference(tb).inMilliseconds.abs() <= 600000;
    }

    final edgeResults = <String, PairSimilarityResult>{};
    PairSimilarityResult evaluatePair(int i, int j) {
      final low = math.min(i, j);
      final high = math.max(i, j);
      final result =
          edgeResults['$low-$high'] ??
          PairSimilarityEvaluator.evaluate(
            sorted[low],
            sorted[high],
            burstWindowSeconds: config.burstWindowSeconds,
            mode: config.mode,
          );
      edgeResults['$low-$high'] = result;
      edgeResults['$high-$low'] = result;
      return result;
    }

    // 2. Multi-channel Candidate Generation
    // Pre-parse 64-bit pHash for fast bitwise Hamming distance
    final pHashValues = List<int?>.filled(n, null);
    for (int i = 0; i < n; i++) {
      final h = sorted[i].pHashHex;
      if (RegExp(r'^[0-9a-fA-F]{1,16}$').hasMatch(h) &&
          h != '0000000000000000') {
        pHashValues[i] = int.tryParse(h, radix: 16);
      }
    }

    int? calcFastPHash(int i, int j) {
      final a = pHashValues[i];
      final b = pHashValues[j];
      if (a == null || b == null) return null;
      var v = a ^ b;
      v = v - ((v >> 1) & 0x5555555555555555);
      v = (v & 0x3333333333333333) + ((v >> 2) & 0x3333333333333333);
      v = (v + (v >> 4)) & 0x0F0F0F0F0F0F0F0F;
      final count = ((v * 0x0101010101010101) >> 56) & 0x7F;
      return count > 64 ? 64 : count;
    }

    final candidatePairs = <int, Set<int>>{};
    for (int i = 0; i < n; i++) {
      candidatePairs[i] = <int>{};
    }

    for (int i = 0; i < n; i++) {
      final a = sorted[i];
      final ta = a.capturedAt;
      final visualCandidates = temporalIndex
          .candidates(i, subjectMode: portraitMode)
          .toList();

      // Scored candidate list for photo i: Map<candidateIndex, priorityScore>
      final candidateScores = <int, double>{};

      // a) Time proximity (adjacent photos or within 180 seconds)
      final timeRange = 15; // adjacent window
      final startJ = math.max(0, i - timeRange);
      final endJ = math.min(n - 1, i + timeRange);
      for (int j = startJ; j <= endJ; j++) {
        if (i == j || !eligible(i, j)) continue;
        final tb = sorted[j].capturedAt;
        if (ta != null && tb != null) {
          final diffSec = (ta.difference(tb).inMilliseconds.abs() / 1000.0);
          if (diffSec <= 180.0) {
            candidateScores[j] =
                (candidateScores[j] ?? 0.0) +
                math.max(0.0, 30.0 - (diffSec / 6.0));
          }
        } else {
          // If no timestamp, adjacent index proximity
          candidateScores[j] = (candidateScores[j] ?? 0.0) + 15.0;
        }
      }

      // b) Fast pHash scan across entire session
      for (final j in visualCandidates) {
        final pDist = calcFastPHash(i, j);
        if (pDist != null && pDist <= 32) {
          final pScore = (34 - pDist) * 2.5;
          candidateScores[j] = (candidateScores[j] ?? 0.0) + pScore;
        }
      }

      // c) Color distance computed only for candidates with initial priority or adjacency
      for (final j in candidateScores.keys.toList()) {
        final cDist = _calcColorDistance(a, sorted[j]);
        if (cDist != null && cDist <= 0.35) {
          candidateScores[j] =
              (candidateScores[j] ?? 0.0) +
              math.max(0.0, (0.40 - cDist) * 80.0);
        }
      }

      // d) Semantic objects
      if (a.semanticObjects.isNotEmpty) {
        final labels = a.semanticObjects.map((object) => object.label).toSet();
        for (final j in visualCandidates) {
          final b = sorted[j];
          if (b.semanticObjects.any(
            (object) => labels.contains(object.label),
          )) {
            candidateScores[j] = (candidateScores[j] ?? 0.0) + 25.0;
          }
        }
      }

      // e) Embedding similarity (if available)
      if (a.embeddings != null) {
        for (final j in visualCandidates) {
          final b = sorted[j];
          if (b.embeddings != null) {
            final (embSim, _) = _calcBestEmbeddingSimilarity(a, b);
            if (embSim != null && embSim >= 0.70) {
              candidateScores[j] =
                  (candidateScores[j] ?? 0.0) +
                  (embSim * (portraitMode ? 140.0 : 50.0));
            }
          }
        }
      }

      // Bound expensive ORB evaluation; retrieval is still quadratic for
      // untimed libraries and portrait mode until an ANN index is introduced.
      final sortedCandidates = candidateScores.keys.toList()
        ..sort((x, y) {
          final cmp = candidateScores[y]!.compareTo(candidateScores[x]!);
          return cmp != 0 ? cmp : x.compareTo(y);
        });

      final topCandidates = sortedCandidates.take(config.maxCandidatesPerPhoto);
      for (final cand in topCandidates) {
        final minIdx = math.min(i, cand);
        final maxIdx = math.max(i, cand);
        candidatePairs[minIdx]!.add(maxIdx);
      }
    }

    // 3. Pairwise Evaluation for Selected Candidate Edges
    for (int i = 0; i < n; i++) {
      for (final j in candidatePairs[i]!) {
        final pairKey = '$i-$j';
        final revKey = '$j-$i';
        final result = evaluatePair(i, j);
        edgeResults[pairKey] = result;
        edgeResults[revKey] = result;
      }
    }

    // 4. Constrained Agglomerative Clustering (Optimized Graph & Cache based)
    // Index candidate edges for fast adjacent cluster discovery
    final photoAdjacency = <int, List<int>>{};
    for (final key in edgeResults.keys) {
      final parts = key.split('-');
      if (parts.length == 2) {
        final u = int.tryParse(parts[0]);
        final v = int.tryParse(parts[1]);
        if (u != null && v != null && u < v) {
          photoAdjacency.putIfAbsent(u, () => []).add(v);
          photoAdjacency.putIfAbsent(v, () => []).add(u);
        }
      }
    }

    final clusterMembers = <int, List<int>>{
      for (int i = 0; i < n; i++) i: [i],
    };
    final photoToCluster = List<int>.generate(n, (i) => i);
    final clusterNeedsReviewMap = <int, bool>{
      for (int i = 0; i < n; i++) i: false,
    };
    final activeClusterIds = <int>{for (int i = 0; i < n; i++) i};

    Set<int> getAdjacentClusters(int cId) {
      final neighbors = <int>{};
      final members = clusterMembers[cId] ?? const [];
      for (final u in members) {
        for (final v in photoAdjacency[u] ?? const <int>[]) {
          final otherC = photoToCluster[v];
          if (otherC != cId) {
            neighbors.add(otherC);
          }
        }
      }
      return neighbors;
    }

    (double, bool)? evalClusterPair(int aId, int bId) {
      final cA = clusterMembers[aId]!;
      final cB = clusterMembers[bId]!;

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
              hasForbiddenEdge =
                  true; // Same subject but different event: NEVER merge!
            }
            if (res.canGroup) {
              hasSameSceneEdge = true;
              totalConfidence += res.confidence;
              connectedCount++;
              if (res.needsReview) edgeNeedsReview = true;
            }
          }
        }
      }

      if (hasForbiddenEdge || !hasSameSceneEdge || connectedCount == 0) {
        return null;
      }

      // Multi-representative Verification (Check top 3 from each cluster)
      final repsA = _getRepresentatives(cA, sorted, edgeResults, 3);
      final repsB = _getRepresentatives(cB, sorted, edgeResults, 3);

      for (final rA in repsA) {
        for (final rB in repsB) {
          final res = edgeResults['$rA-$rB'] ??= evaluatePair(rA, rB);
          edgeResults['$rB-$rA'] = res;
          if (res.category == PairCategory.sameSubjectDifferentEvent ||
              (res.category == PairCategory.different &&
                  res.confidence >= 0.85)) {
            return null;
          }
          // If directly evaluated as same scene (e.g. valid zoom or verified burst), not a drift violation
          if (res.canGroup) {
            edgeNeedsReview = edgeNeedsReview || res.needsReview;
            continue;
          }

          // Extreme difference between representatives prevents chaining drift
          final pDist = res.pHashDistance ?? 64;
          final inliers = res.orbInliers ?? 0;

          // If within rapid burst (<= 3s) with identical camera/focal EXIF, allow natural burst movement up to 21 bits
          final isSameExifBurst =
              res.diffSeconds != null &&
              res.diffSeconds! <= 3.0 &&
              _hasIdenticalExif(sorted[rA], sorted[rB]);
          final effectiveLimit = isSameExifBurst
              ? math.max(26, config.maxDriftPHashDistance)
              : config.maxDriftPHashDistance;

          if (pDist >= effectiveLimit && inliers < 5) {
            return null; // drift violation
          }
        }
      }

      final avgAffinity = totalConfidence / connectedCount;
      if (avgAffinity >= 0.65) {
        return (avgAffinity, edgeNeedsReview);
      }
      return null;
    }

    // Cache cluster pair evaluations: 'minId-maxId' -> (avgAffinity, needsReview)
    final pairAffinityCache = <String, (double, bool)>{};

    for (final cId in activeClusterIds) {
      for (final neighbor in getAdjacentClusters(cId)) {
        if (cId < neighbor) {
          final eval = evalClusterPair(cId, neighbor);
          if (eval != null) {
            pairAffinityCache['$cId-$neighbor'] = eval;
          }
        }
      }
    }

    while (pairAffinityCache.isNotEmpty) {
      String? bestKey;
      (double, bool)? bestAffinity;

      for (final entry in pairAffinityCache.entries) {
        if (entry.value.$1 >= 0.65) {
          if (bestAffinity == null || entry.value.$1 > bestAffinity.$1) {
            bestAffinity = entry.value;
            bestKey = entry.key;
          }
        }
      }

      if (bestKey == null || bestAffinity == null) {
        break; // No more valid merges
      }

      final parts = bestKey.split('-');
      final bestA = int.parse(parts[0]);
      final bestB = int.parse(parts[1]);

      // Merge bestB into bestA
      final bMembers = clusterMembers[bestB]!;
      clusterMembers[bestA]!.addAll(bMembers);
      for (final m in bMembers) {
        photoToCluster[m] = bestA;
      }
      if (bestAffinity.$2 || (clusterNeedsReviewMap[bestB] ?? false)) {
        clusterNeedsReviewMap[bestA] = true;
      }
      clusterMembers.remove(bestB);
      clusterNeedsReviewMap.remove(bestB);
      activeClusterIds.remove(bestB);

      // Invalidate cache entries involving bestA or bestB
      pairAffinityCache.removeWhere((k, _) {
        final ids = k.split('-');
        final id1 = int.parse(ids[0]);
        final id2 = int.parse(ids[1]);
        return id1 == bestA || id2 == bestA || id1 == bestB || id2 == bestB;
      });

      // Re-evaluate only adjacent clusters of the updated bestA
      for (final neighbor in getAdjacentClusters(bestA)) {
        final id1 = math.min(bestA, neighbor);
        final id2 = math.max(bestA, neighbor);
        final eval = evalClusterPair(id1, id2);
        if (eval != null) {
          pairAffinityCache['$id1-$id2'] = eval;
        }
      }
    }

    final clusters = clusterMembers.values.toList();
    final clusterNeedsReview = <int, bool>{
      for (int i = 0; i < clusters.length; i++)
        i: clusterNeedsReviewMap[photoToCluster[clusters[i].first]] ?? false,
    };

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
          final res = edgeResults['$member-$other'] ??= evaluatePair(
            member,
            other,
          );
          if (res.canGroup && res.confidence >= 0.60) {
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
      var isGroupNeedsReview = refinedNeedsReview[i];
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
        final anchor = _getRepresentatives(
          clusterIndices,
          sorted,
          edgeResults,
          1,
        ).first;

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
            var reference = anchor;
            var res = edgeResults['$anchor-$idx'] ??= evaluatePair(anchor, idx);
            // A member may be linked through another verified member, rather
            // than directly to the display anchor. Report the actual evidence.
            if (!res.canGroup) {
              for (final other in clusterIndices) {
                if (other == idx) continue;
                final candidate = edgeResults['$other-$idx'] ??= evaluatePair(
                  other,
                  idx,
                );
                if (candidate.canGroup &&
                    (!res.canGroup || candidate.confidence > res.confidence)) {
                  reference = other;
                  res = candidate;
                }
              }
            }
            isGroupNeedsReview =
                isGroupNeedsReview || res.needsReview || !res.canGroup;
            groupItems.add(
              item.copyWith(
                groupExplanation: () => GroupMatchExplanation(
                  matchType: res.category == PairCategory.sameBurst
                      ? '連写結合'
                      : portraitMode
                      ? '被写体分類'
                      : '同シーン分類',
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
                  referenceKey: sorted[reference].key,
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
      if (!portraitMode &&
          !isGroupNeedsReview &&
          groupItems.length > config.autoDeleteKeepTopN) {
        for (int k = config.autoDeleteKeepTopN; k < groupItems.length; k++) {
          final item = groupItems[k];
          // Never auto-delete items flagged for review
          if (item.groupExplanation?.needsReview != true) {
            deleteCandidates.add(item.key);
          }
        }
      }

      final uniquePrefix = DateTime.now().millisecondsSinceEpoch.toRadixString(
        36,
      );
      groups.add(
        PhotoGroup(
          id: 'G_${uniquePrefix}_${groupIdCounter++}',
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

  static List<int> _getRepresentatives(
    List<int> cluster,
    List<PhotoEntry> sorted,
    Map<String, PairSimilarityResult> edgeResults,
    int topK,
  ) {
    if (cluster.length <= topK) return cluster;

    // Centrality must dominate raw sharpness (which can be thousands).
    final maxSharpness = cluster.fold<double>(
      0,
      (maxValue, idx) => math.max(maxValue, sorted[idx].sharpness),
    );
    final scores = <int, double>{};
    for (final idx in cluster) {
      final entry = sorted[idx];
      var score = maxSharpness > 0 ? 0.2 * entry.sharpness / maxSharpness : 0.0;
      for (final other in cluster) {
        if (idx != other) {
          final res = edgeResults['$idx-$other'];
          if (res?.canGroup == true) {
            score += 0.8 * res!.confidence / (cluster.length - 1);
          }
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
  static List<PhotoGroup> _groupLegacy(
    List<PhotoEntry> items,
    GroupingConfig config,
  ) {
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
          if (diffSec <= config.burstWindowSeconds &&
              (pDist == null || pDist <= config.maxPHashHammingDistance)) {
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
          deleteCandidateKeys: groupItems
              .skip(config.autoDeleteKeepTopN)
              .map((e) => e.key)
              .toSet(),
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
  static (double?, String?) _calcBestEmbeddingSimilarity(
    PhotoEntry a,
    PhotoEntry b,
  ) {
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
    final validHash = RegExp(r'^[0-9a-fA-F]{1,16}$');
    if (!validHash.hasMatch(ha) ||
        !validHash.hasMatch(hb) ||
        ha == '0000000000000000' ||
        hb == '0000000000000000') {
      return null;
    }
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
    if (hA == null || hB == null || hA.length != 692 || hB.length != 692) {
      return null;
    }

    double bhattacharyya(int start, int length) {
      double bc = 0.0;
      for (int i = start; i < start + length; i++) {
        bc += math.sqrt(hA[i] * hB[i]);
      }
      final d = (1.0 - bc).clamp(0.0, 1.0);
      return math.sqrt(d);
    }

    final dH = bhattacharyya(0, 180);
    final dS = bhattacharyya(180, 256);
    final dV = bhattacharyya(436, 256);

    return (dH * 0.6) + (dS * 0.2) + (dV * 0.2);
  }

  static bool _isBurstGroup(List<PhotoEntry> items, int burstWindowSeconds) {
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()
      ..sort();
    if (times.length < 2 || times.length != items.length) return false;
    final span = times.last.difference(times.first).inMilliseconds.abs();
    return span <= burstWindowSeconds * 1000;
  }

  static int? _parseIso(String? iso) {
    if (iso == null) return null;
    final m = RegExp(r'\d+').firstMatch(iso);
    if (m != null) return int.tryParse(m.group(0)!);
    return null;
  }

  static bool _hasIdenticalExif(PhotoEntry a, PhotoEntry b) {
    if (a.exif == null || b.exif == null) return false;
    final ea = a.exif!;
    final eb = b.exif!;
    if (ea.cameraModel == null || ea.cameraModel != eb.cameraModel) {
      return false;
    }
    if (ea.fNumber == null || ea.fNumber != eb.fNumber) return false;
    if (ea.iso == null || ea.iso != eb.iso) return false;
    if (ea.focalLength == null || ea.focalLength != eb.focalLength) {
      return false;
    }
    return true;
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
        formula =
            'ピント正規化(${s.toStringAsFixed(2)}) = ${(total * 100).toStringAsFixed(1)}点';
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
}
