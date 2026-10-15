import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';
import 'package:bestshot/src/services/grouping/pair_evaluator.dart';

PhotoEntry photo(
  String key, {
  int? seconds = 0,
  String hash = '123456789abcdef0',
  Map<String, Float32List>? embeddings,
  bool face = false,
  Float32List? colors,
  int rows = 0,
}) => PhotoEntry(
  key: key,
  origin: PhotoOrigin.filePath,
  displayBytes: Uint8List(0),
  pHashHex: hash,
  sharpness: 100,
  exposureScore: 0.8,
  orbRows: rows,
  orbCols: 32,
  orbBytes: Uint8List(0),
  orbKeypoints: Float32List(0),
  histogram: Uint8List(256),
  hueHistogram: colors,
  embeddings: embeddings,
  exif: seconds == null
      ? null
      : ExifSummary(
          fNumber: null,
          iso: null,
          shutter: null,
          capturedAt: DateTime(2026).add(Duration(seconds: seconds)),
        ),
  portrait: PortraitAnalysis(hasFace: face),
);

Map<String, Float32List> subject(double x, double y) => {
  'full': Float32List.fromList([x, y]),
  'center': Float32List.fromList([x, y]),
};

void main() {
  test(
    'portrait joins supported subject evidence across days; normal separates',
    () {
      final items = [
        photo('a', embeddings: subject(1, 0)),
        photo(
          'b',
          seconds: 86400,
          hash: 'fedcba9876543210',
          embeddings: subject(1, 0),
        ),
      ];
      expect(PhotoGrouper.group(items, const GroupingConfig()).length, 2);
      final groups = PhotoGrouper.group(
        items,
        const GroupingConfig(mode: DetectionMode.portrait),
      );
      expect(groups.length, 1);
      expect(groups.single.needsReview, isTrue);
      expect(groups.single.deleteCandidateKeys, isEmpty);
    },
  );

  test(
    'portrait separates different subjects even with matching face presence',
    () {
      final a = photo('a', face: true, embeddings: subject(1, 0));
      final b = photo(
        'b',
        face: true,
        seconds: 86400,
        embeddings: subject(0, 1),
      );
      final result = PairSimilarityEvaluator.evaluate(
        a,
        b,
        mode: DetectionMode.portrait,
      );
      expect(result.isSameScene, isFalse);
      expect(result.semanticMatch, isFalse);
      expect(result.category, PairCategory.different);
    },
  );

  test(
    'one matching corner is insufficient for cross-session portrait grouping',
    () {
      final a = photo('a', embeddings: subject(1, 0));
      final b = photo(
        'b',
        seconds: 86400,
        embeddings: {
          'full': Float32List.fromList([0, 1]),
          'center': Float32List.fromList([0, 1]),
          'tl': Float32List.fromList([1, 0]),
        },
      );
      expect(
        PairSimilarityEvaluator.evaluate(
          a,
          b,
          mode: DetectionMode.portrait,
        ).isSameScene,
        isFalse,
      );
    },
  );

  test(
    'normal embedding without geometry, hash or color support cannot merge',
    () {
      final a = photo('a', embeddings: subject(1, 0));
      final b = photo(
        'b',
        seconds: 60,
        hash: 'fedcba9876543210',
        embeddings: subject(1, 0),
      );
      expect(PairSimilarityEvaluator.evaluate(a, b).isSameScene, isFalse);
    },
  );

  test('normal keeps a visually similar burst', () {
    expect(
      PhotoGrouper.group([
        photo('a'),
        photo('b', seconds: 1),
      ], const GroupingConfig()).length,
      1,
    );
  });

  test('portrait subject classification does not claim the same scene', () {
    final result = PairSimilarityEvaluator.evaluate(
      photo('a', embeddings: subject(1, 0)),
      photo('b', seconds: 86400, embeddings: subject(1, 0)),
      mode: DetectionMode.portrait,
    );
    expect(result.category, PairCategory.sameSubject);
    expect(result.canGroup, isTrue);
    expect(result.isSameScene, isFalse);
  });

  test(
    'background grouping preserves portrait mode through the isolate',
    () async {
      final groups = await PhotoGrouper.groupAsync([
        photo('a', embeddings: subject(1, 0)),
        photo('b', seconds: 86400, embeddings: subject(1, 0)),
      ], const GroupingConfig(mode: DetectionMode.portrait));
      expect(groups.length, 1);
      expect(groups.single.deleteCandidateKeys, isEmpty);
    },
  );

  test('time alone does not imply same subject', () {
    expect(
      PairSimilarityEvaluator.evaluate(
        photo('a'),
        photo('b', seconds: 86400),
      ).category,
      PairCategory.different,
    );
  });

  test('malformed keypoints and signed pHash do not crash or loop', () {
    final result = PairSimilarityEvaluator.evaluate(
      photo('a', rows: 10, hash: '-1'),
      photo('b', rows: 10),
    );
    expect(result.pHashDistance, isNull);
    expect(result.isSameScene, isFalse);
  });

  test('NaN embedding is never evidence', () {
    final result = PairSimilarityEvaluator.evaluate(
      photo('a', seconds: null, hash: '', embeddings: subject(double.nan, 0)),
      photo('b', seconds: null, hash: '', embeddings: subject(1, 0)),
      mode: DetectionMode.portrait,
    );
    expect(result.isSameScene, isFalse);
  });
}
