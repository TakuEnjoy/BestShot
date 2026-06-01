import '../../models/photo_entry.dart';
import '../../models/photo_group.dart';

class GroupingConfig {
  const GroupingConfig({
    this.burstWindowSeconds = 15, // Tightened from 30
    this.relaxedTimeWindowMinutes = 1,
    this.semanticTimeWindowMinutes = 3, // Tightened from 5
    this.maxPHashHammingDistance = 14, // Much tighter from 24
    this.semanticMinMatches = 2, // Tightened from 1
    this.semanticMinIoU = 0.4, // Tightened from 0.25
    this.autoDeleteKeepTopN = 1,
    this.orbMinMatches = 30, // Much tighter from 15
    this.orbMaxHammingDist = 45, // Tighter from 55
  });

  /// If both photos have EXIF time and diff <= this value, force same group (burst).
  final int burstWindowSeconds;

  /// If both photos have EXIF time and diff <= this value (minutes), group even if pHash differs somewhat.
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
}

class PhotoGrouper {
  static List<PhotoGroup> group(List<PhotoEntry> items, GroupingConfig config) {
    if (items.isEmpty) return [];

    // Use Union-Find or simple BFS to find connected components (transitive closure).
    final parent = <String, String>{};
    for (final e in items) {
      parent[e.key] = e.key;
    }

    String find(String k) {
      if (parent[k] == k) return k;
      return parent[k] = find(parent[k]!);
    }

    void union(String a, String b) {
      final rootA = find(a);
      final rootB = find(b);
      if (rootA != rootB) {
        parent[rootA] = rootB;
      }
    }

    // Sort items by time to compare only nearby items (optimization).
    final sorted = items.toList()
      ..sort((a, b) {
        final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ta.compareTo(tb);
      });

    for (var i = 0; i < sorted.length; i++) {
      // Compare with items within a reasonable time window (e.g. 10 mins).
      for (var j = i + 1; j < sorted.length; j++) {
        final a = sorted[i];
        final b = sorted[j];

        // If time diff > 10 mins, stop comparing for this 'i' (assuming sorted by time).
        final ta = a.capturedAt;
        final tb = b.capturedAt;
        if (ta != null &&
            tb != null &&
            tb.difference(ta).inMinutes.abs() > 10) {
          break;
        }

        if (_similar(a, b, config)) {
          union(a.key, b.key);
        }
      }
    }

    // Group items by root.
    final groupsMap = <String, List<PhotoEntry>>{};
    for (final e in items) {
      final root = find(e.key);
      groupsMap.putIfAbsent(root, () => []).add(e);
    }

    final groups = <PhotoGroup>[];
    var groupIdCounter = 1;

    for (final entry in groupsMap.entries) {
      final groupItems = entry.value;
      final isBurstGroup = _isBurstGroup(groupItems, config.burstWindowSeconds);

      // Best selection:
      _reorderAndMarkBest(groupItems, isBurstGroup, config);
      final best = groupItems.first;

      // Changed: Initial delete candidates are empty as requested.
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

    // Sort groups by the earliest capturedAt time in each group (ascending)
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
    if (items.length <= 1) return;

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

    double score(PhotoEntry e) {
      final iso = _parseIso(e.exif?.iso);
      var eff = e.sharpness;
      if (iso != null && iso > 800) {
        eff = e.sharpness / (1.0 + (iso - 800) * 0.00015);
      }

      // Normalize effective sharpness within this group (0..1).
      final s = (eff / maxEffectiveSharp).clamp(0.0, 1.0);
      final x = e.exposureScore.clamp(0.0, 1.0);
      final f = e.faceQualityScore.clamp(0.0, 1.0);

      if (isBurst) {
        // Burst: usually small framing changes; sharpness is king.
        return s;
      }

      if (f > 0) {
        // If faces detected: priority is Face Quality > Sharpness > Exposure.
        // Reduced exposure weight (0.15 -> 0.05) and increased sharpness weight (0.25 -> 0.35)
        return (f * 0.6) + (s * 0.35) + (x * 0.05);
      }

      // No faces: Sharpness and Exposure.
      // Reduced exposure weight (0.4 -> 0.2) and increased sharpness weight (0.6 -> 0.8)
      return (s * 0.8) + (x * 0.2);
    }

    items.sort((a, b) => score(b).compareTo(score(a)));
  }

  static bool _similar(PhotoEntry a, PhotoEntry b, GroupingConfig config) {
    // 1) Burst priority: <= 30 seconds => same group.
    if (_isTimeCloseSeconds(a, b, config.burstWindowSeconds)) return true;

    // 2) Semantic grouping: time <= 5 min AND objects align.
    if (_isTimeCloseMinutes(a, b, config.semanticTimeWindowMinutes) &&
        _semanticSimilar(a, b, config)) {
      return true;
    }

    // 3) Feature similarity (ORB): more robust than pHash for camera movement.
    if (_orbSimilar(a, b, config)) return true;

    // 4) pHash: standard fallback for visual similarity.
    if (_pHashClose(a, b, config.maxPHashHammingDistance)) return true;

    // Removed the "relaxed time" rule that grouped everything within 1 minute.
    return false;
  }

  static bool _orbSimilar(PhotoEntry a, PhotoEntry b, GroupingConfig config) {
    if (a.orbRows == 0 || b.orbRows == 0) return false;
    if (a.orbBytes.isEmpty || b.orbBytes.isEmpty) return false;

    var matches = 0;
    final rA = a.orbRows;
    final rB = b.orbRows;
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
          // Popcount
          while (x != 0) {
            x &= (x - 1);
            dist++;
          }
          if (dist >= bestDist) break;
        }
        if (dist < bestDist) {
          bestDist = dist;
        }
        if (bestDist <= config.orbMaxHammingDist) break;
      }

      if (bestDist <= config.orbMaxHammingDist) {
        matches++;
      }
    }

    return matches >= config.orbMinMatches;
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

  static bool _isTimeCloseSeconds(
    PhotoEntry a,
    PhotoEntry b,
    int windowSeconds,
  ) {
    final ta = a.capturedAt;
    final tb = b.capturedAt;
    if (ta == null || tb == null) return false;
    final diff = ta.difference(tb).inSeconds.abs();
    return diff <= windowSeconds;
  }

  static bool _isTimeCloseMinutes(
    PhotoEntry a,
    PhotoEntry b,
    int windowMinutes,
  ) {
    final ta = a.capturedAt;
    final tb = b.capturedAt;
    if (ta == null || tb == null) return false;
    final diff = ta.difference(tb).inSeconds.abs();
    return diff <= (windowMinutes * 60);
  }

  static bool _isBurstGroup(List<PhotoEntry> items, int burstWindowSeconds) {
    // Burst group if at least 2 photos have times within [burstWindowSeconds] range.
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()
      ..sort();
    if (times.length < 2) return false;
    final span = times.last.difference(times.first).inSeconds.abs();
    return span <= burstWindowSeconds;
  }

  static bool _pHashClose(PhotoEntry a, PhotoEntry b, int maxDist) {
    final ha = a.pHashHex;
    final hb = b.pHashHex;
    if (ha.isEmpty || hb.isEmpty) return false;
    if (ha == '0000000000000000' || hb == '0000000000000000') return false;
    final d = _hammingDistance64Hex(ha, hb);
    return d <= maxDist;
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
}
