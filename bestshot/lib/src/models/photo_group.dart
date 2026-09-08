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
