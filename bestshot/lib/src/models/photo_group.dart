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

  late final String timeRange = _computeTimeRange();
  String _computeTimeRange() {
    if (items.isEmpty) return '';
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.isEmpty) return '時刻不明';
    final first = times.first;
    final last = times.last;
    final fStr = '${first.hour.toString().padLeft(2, '0')}:${first.minute.toString().padLeft(2, '0')}';
    if (first == last) return fStr;
    final lStr = '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
    return '$fStr - $lStr';
  }

  late final String burstDuration = _computeBurstDuration();
  String _computeBurstDuration() {
    if (!isBurst) return '単写';
    final times = items.map((e) => e.capturedAt).whereType<DateTime>().toList()..sort();
    if (times.length < 2) return '連写';
    final diffMs = times.last.difference(times.first).inMilliseconds;
    final sec = (diffMs / 1000.0).toStringAsFixed(1);
    return '連写: $sec秒間';
  }

  late final int? geometricMatchRate = _computeGeometricMatchRate();
  int? _computeGeometricMatchRate() {
    for (final item in items) {
      final exp = item.groupExplanation;
      if (exp != null && exp.inliers != null && exp.inliers! > 0) {
        final ratio = ((exp.orbInlierRatio ?? 0.3) * 100).round().clamp(60, 99);
        return ratio;
      }
    }
    return null;
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
