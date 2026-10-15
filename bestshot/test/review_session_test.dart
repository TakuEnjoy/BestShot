import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/models/photo_group.dart';
import 'package:bestshot/src/models/review_session.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';
import 'package:bestshot/src/services/review_session_store.dart';
import 'grouping_modes_test.dart' show photo;

PhotoGroup group(String id, List<PhotoEntry> items, {bool review = false}) =>
    PhotoGroup(
      id: id,
      items: items,
      bestKey: items.first.key,
      deleteCandidateKeys: items.skip(1).map((e) => e.key),
      isBurst: false,
      needsReview: review,
    );

void main() {
  test('split and merge preserve each photo, valid bests and safety state', () {
    final s = ReviewSession(
      groups: [
        group('g', [photo('a'), photo('b'), photo('c')]),
      ],
      mode: DetectionMode.standard,
    );
    s.groupNames['g'] = '家族';
    s.reviewedGroupIds.add('g');
    s.deleteKeys.addAll(['a', 'b']);
    s.setProtected('b', true);
    s.setDecision('c', PhotoDecision.keep);
    s.split('g', {'a'});
    expect(s.groups.map((g) => g.bestKey), ['b', 'a']);
    expect(s.reviewedGroupIds, isEmpty);
    expect(s.deleteKeys, isEmpty);
    expect(
      s.groups.every(
        (g) => g.needsReview && !g.isBurst && g.deleteCandidateKeys.isEmpty,
      ),
      isTrue,
    );
    expect(s.groupNames['manual_1'], '家族・分割');
    s.merge({'g', 'manual_1'});
    expect(s.groups.single.items.map((e) => e.key).toSet(), {'a', 'b', 'c'});
    expect(s.groups.single.bestKey, 'b');
    expect(s.protectedKeys, {'b'});
    expect(s.decisions['c'], PhotoDecision.keep);
    expect(s.groupNames, {'g': '家族'});
  });

  test('invalid edits do not mutate the groups', () {
    final s = ReviewSession(
      groups: [
        group('g', [photo('a'), photo('b')]),
      ],
      mode: DetectionMode.standard,
    );
    final original = s.groups;
    expect(() => s.split('g', {}), throwsArgumentError);
    expect(() => s.split('g', {'a', 'b'}), throwsArgumentError);
    expect(() => s.merge({'g'}), throwsArgumentError);
    expect(identical(original, s.groups), isTrue);
  });

  test(
    'keep, hold and protection veto deletion; exclusion does not delete',
    () {
      final s = ReviewSession(groups: [], mode: DetectionMode.standard);
      for (final value in PhotoDecision.values) {
        s.deleteKeys.add('a');
        s.setDecision('a', value);
        expect(
          s.canDelete('a'),
          value == PhotoDecision.undecided || value == PhotoDecision.exclude,
        );
        expect(s.canMove('a'), isTrue);
      }
      s.deleteKeys.clear();
      s.setDecision('a', PhotoDecision.exclude);
      expect(s.deleteKeys, isEmpty);
      s.setProtected('a', true);
      expect(s.canDelete('a'), isFalse);
      expect(s.canMove('a'), isFalse);
      s.setProtected('a', false);
      expect(s.canDelete('a'), isTrue);
    },
  );

  test('all date, size, uncertainty and filename orders are deterministic', () {
    final a = photo(
      'a',
      seconds: 10,
    ).copyWith(filePath: () => r'C:\photos\Z.jpg');
    final b = photo('b', seconds: 20).copyWith(filePath: () => '/photos/a.jpg');
    final c = photo('c', seconds: null);
    final s = ReviewSession(
      groups: [
        group('g1', [a, b]),
        group('g2', [c], review: true),
      ],
      mode: DetectionMode.standard,
    );
    for (final order in [PhotoOrder.oldest, PhotoOrder.newest]) {
      expect(
        s.sortedPhotos([c, b, a], order: order).map((e) => e.key),
        order == PhotoOrder.oldest ? ['a', 'b', 'c'] : ['b', 'a', 'c'],
      );
    }
    expect(
      s.sortedPhotos([a, b], order: PhotoOrder.filename).map((e) => e.key),
      ['b', 'a'],
    );
    expect(
      s
          .sortedPhotos([a, b], order: PhotoOrder.filenameDescending)
          .map((e) => e.key),
      ['a', 'b'],
    );
    for (final order in GroupOrder.values) {
      s.groupOrder = order;
      final first = s.sortedGroups(s.groups).first.id;
      expect(
        first,
        [GroupOrder.fewestPhotos, GroupOrder.reviewFirst].contains(order)
            ? 'g2'
            : 'g1',
      );
    }
    s.groupOrder = GroupOrder.reviewFirst;
    expect(
      s.sortedPhotos([a, c, b], order: PhotoOrder.subject).map((e) => e.key),
      ['c', 'a', 'b'],
    );
    expect(s.groups.first.items.map((e) => e.key), [
      'a',
      'b',
    ]); // Sorting is non-mutating.
    expect(s.groups.first.bestKey, 'a');
  });

  test('recommended uses analysis score, not sharpness alone', () {
    final a = photo('a').copyWith(sharpness: 100, exposureScore: 0);
    final b = photo('b').copyWith(sharpness: 90, exposureScore: 1);
    final s = ReviewSession(
      groups: [
        group('g', [a, b]),
      ],
      mode: DetectionMode.standard,
    );
    expect(s.sortedPhotos([a, b]).first.key, 'b');
    final scored = a.copyWith(
      scoreExplanation: () => const ScoreExplanation(
        totalScore: 1,
        rawSharpness: 100,
        effectiveSharpness: 100,
        normalizedSharpness: 1,
        exposureScore: 0,
        faceQualityScore: 0,
        ruleName: 'test',
        formulaText: 'test',
      ),
    );
    expect(s.sortedPhotos([scored, b]).first.key, 'a');
  });

  test(
    'face quality sorts eyes-open then closed then no face; unknown is neutral',
    () {
      final open = photo('open').copyWith(
        portrait: const PortraitAnalysis(
          hasFace: true,
          eyeOpenAvg: 0.9,
          faceSharpness: 100,
        ),
      );
      final closed = photo('closed').copyWith(
        portrait: const PortraitAnalysis(
          hasFace: true,
          eyesClosed: true,
          faceSharpness: 100,
        ),
      );
      final unknown = photo('unknown').copyWith(
        portrait: const PortraitAnalysis(hasFace: true, eyeOpenAvg: -1),
      );
      final none = photo('none');
      final s = ReviewSession(
        groups: [
          group('g', [none, closed, open, unknown]),
        ],
        mode: DetectionMode.portrait,
      );
      expect(
        s
            .sortedPhotos(s.groups.single.items, order: PhotoOrder.faceQuality)
            .map((e) => e.key),
        ['open', 'unknown', 'closed', 'none'],
      );
    },
  );

  test('compressed snapshot round-trips full analysis and review state', () {
    final a =
        photo(
          'a',
          face: true,
          embeddings: {
            'full': Float32List.fromList([0.2, 0.8]),
          },
        ).copyWith(
          filePath: () => r'C:\photos\a.jpg',
          displayBytes: Uint8List.fromList([1, 2, 3]),
          groupExplanation: () => const GroupMatchExplanation(
            matchType: 'subject',
            description: '同一被写体',
            referenceKey: 'b',
            confidence: 0.8,
            needsReview: true,
          ),
          semanticObjects: [
            const SemanticObject(label: 'person', x: 1, y: 2, w: 3, h: 4),
          ],
        );
    final s = ReviewSession(
      groups: [
        group('g', [a, photo('b')]),
      ],
      mode: DetectionMode.portrait,
    );
    s.setDecision('a', PhotoDecision.keep);
    s.setProtected('a', true);
    s.groupNames['g'] = '人物A';
    s.reviewedGroupIds.add('g');
    s.folders['b'] = '候補';
    s.customFolders.add('候補');
    s.deleteKeys.addAll(['a', 'b']);
    s.comparisonKeys.addAll(['a', 'b']);
    s.activeKey = 'b';
    s.groupOrder = GroupOrder.reviewFirst;
    s.photoOrder = PhotoOrder.faceQuality;
    s.unreviewedOnly = true;
    s.decisionFilter = PhotoDecision.hold;
    final restored = ReviewSessionStore.decode(ReviewSessionStore.encode(s));
    final restoredPhoto = restored.groups.single.items.first;
    expect(restoredPhoto.displayBytes, a.displayBytes);
    expect(restoredPhoto.embeddings!['full'], a.embeddings!['full']);
    expect(restoredPhoto.filePath, a.filePath);
    expect(restoredPhoto.capturedAt, a.capturedAt);
    expect(restoredPhoto.portrait, a.portrait);
    expect(restoredPhoto.semanticObjects.single.label, 'person');
    expect(restoredPhoto.groupExplanation!.referenceKey, 'b');
    expect(restored.mode, DetectionMode.portrait);
    expect(restored.groups.single.bestKey, 'a');
    expect(restored.decisions, s.decisions);
    expect(restored.protectedKeys, {'a'});
    expect(restored.reviewedGroupIds, {'g'});
    expect(restored.groupNames, s.groupNames);
    expect(restored.folders, s.folders);
    expect(restored.customFolders, s.customFolders);
    expect(restored.deleteKeys, {'b'});
    expect(restored.comparisonKeys, ['a', 'b']);
    expect(restored.activeKey, 'b');
    expect(restored.groupOrder, s.groupOrder);
    expect(restored.photoOrder, s.photoOrder);
    expect(restored.unreviewedOnly, isTrue);
    expect(restored.decisionFilter, PhotoDecision.hold);
  });

  test('malformed or duplicate snapshot content is rejected', () {
    final s = ReviewSession(
      groups: [
        group('g', [photo('a')]),
      ],
      mode: DetectionMode.standard,
    );
    final data =
        jsonDecode(utf8.decode(gzip.decode(ReviewSessionStore.encode(s))))
            as Map<String, dynamic>;
    Uint8List bytes() =>
        Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(data))));
    data['schema'] = 100;
    expect(() => ReviewSessionStore.decode(bytes()), throwsFormatException);
    data['schema'] = 1;
    (data['groups'] as List).add((data['groups'] as List).first);
    expect(() => ReviewSessionStore.decode(bytes()), throwsFormatException);
    expect(
      () => ReviewSessionStore.decode(Uint8List(0)),
      throwsA(isA<Exception>()),
    );
  });

  test(
    'atomic disk save replaces previous snapshot and leaves unrelated files',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'bestshot-review-test-',
      );
      try {
        final path = '${dir.path}/review.bestshot';
        final unrelated = File('$path.tmp');
        await unrelated.writeAsString('leave me');
        final s = ReviewSession(
          groups: [
            group('g', [photo('a')]),
          ],
          mode: DetectionMode.standard,
        );
        await ReviewSessionStore.writeSnapshot(
          path,
          ReviewSessionStore.encode(s),
        );
        s.groupNames['g'] = '変更後';
        await ReviewSessionStore.writeSnapshot(
          path,
          ReviewSessionStore.encode(s),
        );
        expect(
          ReviewSessionStore.decode(
            await File(path).readAsBytes(),
          ).groupNames['g'],
          '変更後',
        );
        expect(await unrelated.readAsString(), 'leave me');
        expect(await dir.list().length, 2);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
