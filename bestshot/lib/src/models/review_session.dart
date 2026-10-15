import 'dart:math' as math;
import 'photo_entry.dart';
import 'photo_group.dart';
import '../services/analysis/analysis_types.dart';

enum PhotoDecision { undecided, keep, hold, exclude }

enum GroupOrder { oldest, newest, mostPhotos, fewestPhotos, reviewFirst }

enum PhotoOrder {
  recommended,
  oldest,
  newest,
  filename,
  filenameDescending,
  subject,
  faceQuality,
}

const decisionLabels = ['未選別', '残す', '保留', '除外'];
const groupOrderLabels = [
  '撮影日時・古い順',
  '撮影日時・新しい順',
  '枚数・多い順',
  '枚数・少ない順',
  '要確認優先',
];
const photoOrderLabels = [
  'おすすめ順',
  '撮影日時・古い順',
  '撮影日時・新しい順',
  'ファイル名・昇順',
  'ファイル名・降順',
  '被写体グループ順',
  '顔の写り順',
];

/// Editable culling state, independent of AI uncertainty and file operations.
class ReviewSession {
  ReviewSession({required this.groups, required this.mode});
  List<PhotoGroup> groups;
  final DetectionMode mode;
  final directoryBookmarks = <String, String>{};
  final decisions = <String, PhotoDecision>{};
  final protectedKeys = <String>{};
  final reviewedGroupIds = <String>{};
  final groupNames = <String, String>{};
  final folders = <String, String>{};
  final customFolders = <String>[];
  final deleteKeys = <String>{};
  final comparisonKeys = <String>[];
  GroupOrder groupOrder = GroupOrder.oldest;
  PhotoOrder photoOrder = PhotoOrder.recommended;
  bool unreviewedOnly = false;
  PhotoDecision? decisionFilter;
  String? activeKey;

  bool canDelete(String key) =>
      !protectedKeys.contains(key) &&
      (decisions[key] == null ||
          decisions[key] == PhotoDecision.undecided ||
          decisions[key] == PhotoDecision.exclude);
  bool canMove(String key) => !protectedKeys.contains(key);
  String name(PhotoGroup group) => groupNames[group.id] ?? group.id;
  String label(String key) {
    final decision = decisions[key] ?? PhotoDecision.undecided;
    return [
      if (protectedKeys.contains(key)) '保護',
      if (decision != PhotoDecision.undecided) decisionLabels[decision.index],
    ].join('・');
  }

  void setDecision(String key, PhotoDecision value) {
    decisions[key] = value;
    if (!canDelete(key)) deleteKeys.remove(key);
  }

  void setProtected(String key, bool value) {
    if (value) {
      protectedKeys.add(key);
      deleteKeys.remove(key);
    } else {
      protectedKeys.remove(key);
    }
  }

  void split(String groupId, Set<String> keys) {
    final index = groups.indexWhere((g) => g.id == groupId);
    if (index < 0) throw ArgumentError('グループが見つかりません');
    final original = groups[index];
    final selected = original.items.where((e) => keys.contains(e.key)).toList();
    final remaining = original.items
        .where((e) => !keys.contains(e.key))
        .toList();
    if (selected.isEmpty || remaining.isEmpty) {
      throw ArgumentError('一部の写真を選択してください');
    }
    final id = _newId();
    PhotoGroup part(String id, List<PhotoEntry> items) => original.copyWith(
      id: id,
      items: items
          .map(
            (e) => e.copyWith(
              groupExplanation: () => null,
              scoreExplanation: () => null,
            ),
          )
          .toList(),
      bestKey: items.any((e) => e.key == original.bestKey)
          ? original.bestKey
          : items.first.key,
      deleteCandidateKeys: [],
      isBurst: false,
      needsReview: true,
    );
    groups = List.of(groups)
      ..replaceRange(index, index + 1, [
        part(original.id, remaining),
        part(id, selected),
      ]);
    groupNames[id] = '${name(original)}・分割';
    reviewedGroupIds.remove(original.id);
    deleteKeys.removeAll(original.items.map((e) => e.key));
  }

  void merge(Set<String> ids) {
    final selected = groups.where((g) => ids.contains(g.id)).toList();
    if (selected.length < 2) throw ArgumentError('2つ以上のグループを選択してください');
    final first = selected.first;
    final photos = selected
        .expand((g) => g.items)
        .map(
          (e) => e.copyWith(
            groupExplanation: () => null,
            scoreExplanation: () => null,
          ),
        )
        .toList();
    final merged = first.copyWith(
      items: photos,
      deleteCandidateKeys: [],
      isBurst: false,
      needsReview: true,
    );
    groups = [
      for (final group in groups)
        if (group.id == first.id)
          merged
        else if (!ids.contains(group.id))
          group,
    ];
    reviewedGroupIds.removeAll(ids);
    for (final id in ids.where((id) => id != first.id)) {
      groupNames.remove(id);
    }
    deleteKeys.removeAll(photos.map((e) => e.key));
  }

  String _newId() {
    var number = 1;
    while (groups.any((g) => g.id == 'manual_$number')) {
      number++;
    }
    return 'manual_$number';
  }

  List<PhotoGroup> sortedGroups(Iterable<PhotoGroup> source) {
    final result = source.toList();
    final timesById = <String, DateTime?>{};
    DateTime? time(PhotoGroup g) {
      if (timesById.containsKey(g.id)) return timesById[g.id];
      final times =
          g.items.map((e) => e.capturedAt).whereType<DateTime>().toList()
            ..sort();
      return timesById[g.id] = times.isEmpty ? null : times.first;
    }

    result.sort((a, b) {
      final value = switch (groupOrder) {
        GroupOrder.oldest => _compareTime(time(a), time(b), false),
        GroupOrder.newest => _compareTime(time(a), time(b), true),
        GroupOrder.mostPhotos => b.items.length.compareTo(a.items.length),
        GroupOrder.fewestPhotos => a.items.length.compareTo(b.items.length),
        GroupOrder.reviewFirst => (b.needsReview ? 1 : 0).compareTo(
          a.needsReview ? 1 : 0,
        ),
      };
      return value != 0 ? value : a.id.compareTo(b.id);
    });
    return result;
  }

  List<PhotoEntry> sortedPhotos(
    Iterable<PhotoEntry> source, {
    PhotoOrder? order,
  }) {
    final selectedOrder = order ?? photoOrder;
    final result = source.toList();
    final keys = result.map((e) => e.key).toSet();
    final relevantGroups = groups
        .where((g) => g.items.any((e) => keys.contains(e.key)))
        .toList();
    final groupByKey = <String, PhotoGroup>{
      for (final g in relevantGroups)
        for (final e in g.items) e.key: g,
    };
    final rank = <String, int>{};
    final ordered = sortedGroups(relevantGroups);
    for (var i = 0; i < ordered.length; i++) {
      rank[ordered[i].id] = i;
    }
    double effectiveSharp(PhotoEntry e) {
      final iso =
          int.tryParse(
            RegExp(r'\d+').firstMatch(e.exif?.iso ?? '')?.group(0) ?? '',
          ) ??
          0;
      final sharp = e.sharpness.isFinite ? math.max(0.0, e.sharpness) : 0.0;
      return iso > 800 ? sharp / (1.0 + (iso - 800) * 0.00015) : sharp;
    }

    final maxSharp = <String, double>{
      for (final g in relevantGroups)
        g.id: g.items.fold<double>(
          0.01,
          (m, e) => math.max(m, effectiveSharp(e)),
        ),
    };
    double quality(PhotoEntry e) {
      final saved = e.scoreExplanation?.totalScore;
      if (saved != null && saved.isFinite) return saved;
      final normalized =
          (effectiveSharp(e) / (maxSharp[groupByKey[e.key]?.id] ?? 1)).clamp(
            0.0,
            1.0,
          );
      final exposure = e.exposureScore.isFinite
          ? e.exposureScore.clamp(0.0, 1.0)
          : 0.0;
      if (groupByKey[e.key]?.isBurst == true) return normalized;
      final face = e.faceQualityScore.isFinite
          ? e.faceQualityScore.clamp(0.0, 1.0)
          : 0.0;
      return face > 0
          ? face * 0.6 + normalized * 0.35 + exposure * 0.05
          : normalized * 0.8 + exposure * 0.2;
    }

    String filename(PhotoEntry e) => (e.originalFilename ?? e.filePath ?? e.key)
        .split(RegExp(r'[/\\]'))
        .last
        .toLowerCase();
    result.sort((a, b) {
      int groupRank() => (rank[groupByKey[a.key]?.id] ?? 0).compareTo(
        rank[groupByKey[b.key]?.id] ?? 0,
      );
      final value = switch (selectedOrder) {
        PhotoOrder.oldest => _compareTime(a.capturedAt, b.capturedAt, false),
        PhotoOrder.newest => _compareTime(a.capturedAt, b.capturedAt, true),
        PhotoOrder.filename => filename(a).compareTo(filename(b)),
        PhotoOrder.filenameDescending => filename(b).compareTo(filename(a)),
        PhotoOrder.subject =>
          groupRank() != 0
              ? groupRank()
              : _compareTime(a.capturedAt, b.capturedAt, false),
        PhotoOrder.faceQuality => faceScore(b).compareTo(faceScore(a)),
        // Quality is comparable within each capture group, not across scenes.
        PhotoOrder.recommended =>
          groupRank() != 0 ? groupRank() : quality(b).compareTo(quality(a)),
      };
      return value != 0 ? value : a.key.compareTo(b.key);
    });
    return result;
  }

  static double faceScore(PhotoEntry e) {
    if (!e.portrait.hasFace) return -1;
    final probability = e.portrait.eyeOpenAvg;
    final eye = e.portrait.eyesClosed
        ? 0.0
        : (probability == null || !probability.isFinite || probability < 0
              ? 0.5
              : probability.clamp(0.0, 1.0));
    final sharp = math.max(0.0, e.portrait.faceSharpness);
    return eye * 0.7 + (sharp.isFinite ? sharp / (sharp + 100) : 0) * 0.3;
  }

  static int _compareTime(DateTime? a, DateTime? b, bool descending) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return descending ? b.compareTo(a) : a.compareTo(b);
  }
}
