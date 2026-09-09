import 'dart:collection';
import 'photo_entry.dart';

class PhotoGroup {
  PhotoGroup({
    required this.id,
    required Iterable<PhotoEntry> items,
    required String bestKey,
    required Iterable<String> deleteCandidateKeys,
    required this.isBurst,
    this.needsReview = false,
  }) : items = UnmodifiableListView(items.toList()),
       deleteCandidateKeys = Set.unmodifiable(deleteCandidateKeys),
       _bestKey = bestKey {
    assert(
      this.items.any((e) => e.key == _bestKey),
      'bestKey must exist in items',
    );
  }

  final String id;
  final List<PhotoEntry> items;
  final Set<String> deleteCandidateKeys;
  final bool isBurst;
  final bool needsReview;

  final String _bestKey;
  String get bestKey => _bestKey;

  String? _cachedTimeRange;
  String get timeRange {
    if (_cachedTimeRange != null) return _cachedTimeRange!;
    if (items.isEmpty) return _cachedTimeRange = '';
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.isEmpty) return _cachedTimeRange = '時刻不明';
    final first = times.first;
    final last = times.last;
    final fStr = '${first.hour.toString().padLeft(2, '0')}:${first.minute.toString().padLeft(2, '0')}';
    if (first == last) return _cachedTimeRange = fStr;
    final lStr = '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
    return _cachedTimeRange = '$fStr - $lStr';
  }

  String? _cachedBurstDuration;
  String get burstDuration {
    if (_cachedBurstDuration != null) return _cachedBurstDuration!;
    if (!isBurst) return _cachedBurstDuration = '単写';
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.length < 2) return _cachedBurstDuration = '連写';
    final diffMs = times.last.difference(times.first).inMilliseconds;
    final sec = (diffMs / 1000.0).toStringAsFixed(1);
    return _cachedBurstDuration = '連写: $sec秒間';
  }

  int? _cachedGeometricMatchRate;
  int get geometricMatchRate {
    if (_cachedGeometricMatchRate != null) return _cachedGeometricMatchRate!;
    for (final item in items) {
      final exp = item.groupExplanation;
      if (exp != null && exp.inliers != null && exp.inliers! > 0) {
        final ratio = ((exp.orbInlierRatio ?? 0.3) * 100).round().clamp(60, 99);
        return _cachedGeometricMatchRate = ratio;
      }
    }
    return _cachedGeometricMatchRate = 88;
  }

  PhotoGroup copyWith({
    String? id,
    Iterable<PhotoEntry>? items,
    String? bestKey,
    Iterable<String>? deleteCandidateKeys,
    bool? isBurst,
    bool? needsReview,
  }) {
    return PhotoGroup(
      id: id ?? this.id,
      items: items ?? this.items,
      bestKey: bestKey ?? this.bestKey,
      deleteCandidateKeys: deleteCandidateKeys ?? this.deleteCandidateKeys,
      isBurst: isBurst ?? this.isBurst,
      needsReview: needsReview ?? this.needsReview,
    );
  }
}
