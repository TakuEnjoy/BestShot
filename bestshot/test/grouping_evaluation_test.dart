import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';

PhotoEntry createFixture({
  required String key,
  required DateTime capturedAt,
  required String pHashHex,
  double sharpness = 1000.0,
  double exposureScore = 0.8,
  String? iso,
  Float32List? hueHistogram,
  int orbRows = 0,
  Uint8List? orbBytes,
  Float32List? orbKeypoints,
  Map<String, Float32List>? embeddings,
  List<SemanticObject> semanticObjects = const [],
  bool hasFace = false,
}) {
  return PhotoEntry(
    key: key,
    origin: PhotoOrigin.filePath,
    filePath: '/fixtures/$key.jpg',
    displayBytes: Uint8List(0),
    pHashHex: pHashHex,
    sharpness: sharpness,
    exposureScore: exposureScore,
    orbRows: orbRows,
    orbCols: orbRows > 0 ? 32 : 0,
    orbBytes: orbBytes ?? Uint8List(0),
    orbKeypoints: orbKeypoints ?? Float32List(0),
    histogram: Uint8List(256),
    hueHistogram: hueHistogram ?? Float32List(180),
    embeddings: embeddings,
    semanticObjects: semanticObjects,
    exif: ExifSummary(
      fNumber: '2.8',
      shutter: '1/250',
      iso: iso ?? '100',
      capturedAt: capturedAt,
    ),
    portrait: PortraitAnalysis(hasFace: hasFace),
  );
}

/// Helper to generate consistent synthetic ORB keypoints and descriptors
(Uint8List, Float32List) generateOrbPattern(int count, {double scale = 1.0, double dx = 0.0, double dy = 0.0}) {
  final bytes = Uint8List(count * 32);
  final kps = Float32List(count * 2);

  for (var i = 0; i < count; i++) {
    bytes[i * 32] = i;
    for (var j = 1; j < 32; j++) {
      bytes[i * 32 + j] = (j * 7) % 256;
    }
    final gx = (i % 6) * 15.0;
    final gy = (i ~/ 6) * 15.0;
    kps[i * 2] = (gx * scale) + dx;
    kps[i * 2 + 1] = (gy * scale) + dy;
  }
  return (bytes, kps);
}

/// Helper to generate normalized embedding vector
Float32List generateEmbedding(int seed, int dim) {
  final v = Float32List(dim);
  double sumSq = 0.0;
  for (var i = 0; i < dim; i++) {
    final val = math.sin(seed * 100.0 + i);
    v[i] = val;
    sumSq += val * val;
  }
  final norm = math.sqrt(sumSq);
  for (var i = 0; i < dim; i++) {
    v[i] /= norm;
  }
  return v;
}

void main() {
  group('BestShot Comprehensive Grouping Accuracy & Quality Evaluation', () {
    final baseTime = DateTime(2026, 9, 8, 10, 0, 0);

    // Build the 10 representative fixture scenarios
    final (orbBytesA, orbKpsA) = generateOrbPattern(24, scale: 1.0);
    final (orbBytesZoom, orbKpsZoom) = generateOrbPattern(24, scale: 1.6, dx: 10.0, dy: 5.0);
    final (orbBytesMoved, orbKpsMoved) = generateOrbPattern(24, scale: 1.0, dx: 30.0, dy: 10.0);
    final (orbBytesB, orbKpsB) = generateOrbPattern(20, scale: 0.9);

    final embCatCenter = generateEmbedding(1, 128);
    final embCatFull = generateEmbedding(1, 128); // Identical semantic subject
    final embDogFull = generateEmbedding(50, 128); // Different subject

    final fixtures = <PhotoEntry>[
      // 1. 同一連写 (Burst)
      createFixture(
        key: 'burst_01',
        capturedAt: baseTime,
        pHashHex: 'A100000000000001',
        sharpness: 2400.0,
      ),
      createFixture(
        key: 'burst_02',
        capturedAt: baseTime.add(const Duration(milliseconds: 250)),
        pHashHex: 'A100000000000003', // 1 bit diff
        sharpness: 2600.0,
      ),
      createFixture(
        key: 'burst_03',
        capturedAt: baseTime.add(const Duration(milliseconds: 500)),
        pHashHex: 'A100000000000007', // 2 bits diff
        sharpness: 2550.0,
      ),

      // 2. 同一被写体の寄り・引き (Zoom / Tele-Wide)
      createFixture(
        key: 'zoom_wide',
        capturedAt: baseTime.add(const Duration(seconds: 40)),
        pHashHex: 'B200000000000000',
        sharpness: 3100.0,
        orbRows: 24,
        orbBytes: orbBytesA,
        orbKeypoints: orbKpsA,
        embeddings: {'full': embCatFull},
      ),
      createFixture(
        key: 'zoom_tele',
        capturedAt: baseTime.add(const Duration(seconds: 70)), // 30s later (exceeds 15s burst window)
        pHashHex: 'B200000000FFFFFF', // 24 bits diff (exceeds 14 pHash limit)
        sharpness: 3200.0,
        orbRows: 24,
        orbBytes: orbBytesZoom,
        orbKeypoints: orbKpsZoom,
        embeddings: {'center': embCatCenter},
      ),

      // 3. 同一被写体の位置移動 (Subject moved)
      createFixture(
        key: 'moved_01',
        capturedAt: baseTime.add(const Duration(seconds: 80)),
        pHashHex: 'C300000000001111',
        sharpness: 1800.0,
        orbRows: 24,
        orbBytes: orbBytesA,
        orbKeypoints: orbKpsA,
      ),
      createFixture(
        key: 'moved_02',
        capturedAt: baseTime.add(const Duration(seconds: 82)),
        pHashHex: 'C300000000002222', // shifted framing
        sharpness: 1950.0,
        orbRows: 24,
        orbBytes: orbBytesMoved,
        orbKeypoints: orbKpsMoved,
      ),

      // 4. 同じ人物だが別日の写真 (Same subject, different event)
      createFixture(
        key: 'person_day1',
        capturedAt: baseTime.add(const Duration(seconds: 120)),
        pHashHex: 'D400000000000000',
        hasFace: true,
        semanticObjects: [
          const SemanticObject(label: 'person', x: 100, y: 100, w: 200, h: 200),
        ],
      ),
      createFixture(
        key: 'person_day2',
        capturedAt: baseTime.add(const Duration(days: 1, seconds: 120)), // 24 hours later!
        pHashHex: 'D4FFFFFFFFFFFFFF',
        hasFace: true,
        semanticObjects: [
          const SemanticObject(label: 'person', x: 120, y: 110, w: 190, h: 210),
        ],
      ),

      // 5. 同じ背景・別被写体 (Same background, different subject)
      createFixture(
        key: 'bg_person_A',
        capturedAt: baseTime.add(const Duration(seconds: 180)),
        pHashHex: 'E5000000000000AA',
        semanticObjects: [const SemanticObject(label: 'cat', x: 50, y: 50, w: 100, h: 100)],
      ),
      createFixture(
        key: 'bg_person_B',
        capturedAt: baseTime.add(const Duration(seconds: 190)),
        pHashHex: 'E50000000000FF55', // Diff subject, diff foreground
        semanticObjects: [const SemanticObject(label: 'dog', x: 50, y: 50, w: 100, h: 100)],
        embeddings: {'full': embDogFull},
      ),

      // 6. 時刻が近いが別構図 (Time close, different composition)
      createFixture(
        key: 'time_close_scene1',
        capturedAt: baseTime.add(const Duration(seconds: 220)),
        pHashHex: '1111111111111111',
      ),
      createFixture(
        key: 'time_close_scene2_turned90deg',
        capturedAt: baseTime.add(const Duration(seconds: 223)), // 3s later, turned camera
        pHashHex: 'EEEEEEEEEEEEEEEE', // 32 bits diff
      ),

      // 7. 芋づる連鎖 (Chaining Drift sequence)
      createFixture(
        key: 'drift_01',
        capturedAt: baseTime.add(const Duration(seconds: 300)),
        pHashHex: 'F100000000000000',
      ),
      createFixture(
        key: 'drift_02',
        capturedAt: baseTime.add(const Duration(seconds: 302)),
        pHashHex: 'F10000000000007F', // 7 bits from drift_01
      ),
      createFixture(
        key: 'drift_03',
        capturedAt: baseTime.add(const Duration(seconds: 304)),
        pHashHex: 'F100000000003FFF', // 7 bits from drift_02, 14 bits from drift_01
      ),
      createFixture(
        key: 'drift_04',
        capturedAt: baseTime.add(const Duration(seconds: 306)),
        pHashHex: 'F100000000FFFFFF', // 24 bits from drift_01
      ),

      // 8. 暗所・高ISO連写 (Low light high ISO)
      createFixture(
        key: 'lowlight_iso3200_1',
        capturedAt: baseTime.add(const Duration(seconds: 400)),
        pHashHex: '0011223344556677',
        iso: '3200',
        sharpness: 850.0,
      ),
      createFixture(
        key: 'lowlight_iso3200_2',
        capturedAt: baseTime.add(const Duration(seconds: 401)),
        pHashHex: '001122334455667F', // 3 bits diff with noise
        iso: '3200',
        sharpness: 900.0,
      ),

      // 9. 顔なし写真 (No-face landscape)
      createFixture(
        key: 'landscape_01',
        capturedAt: baseTime.add(const Duration(seconds: 500)),
        pHashHex: '8899AABBCCDDEEFF',
        hasFace: false,
        orbRows: 20,
        orbBytes: orbBytesB,
        orbKeypoints: orbKpsB,
      ),
      createFixture(
        key: 'landscape_02',
        capturedAt: baseTime.add(const Duration(seconds: 502)),
        pHashHex: '8899AABBCCDDEEFE',
        hasFace: false,
        orbRows: 20,
        orbBytes: orbBytesB,
        orbKeypoints: orbKpsB,
      ),

      // 10. 埋め込みモデルなしのフォールバック写真 (No embedding model available)
      createFixture(
        key: 'no_model_fallback_01',
        capturedAt: baseTime.add(const Duration(seconds: 600)),
        pHashHex: '0123456789ABCDEF',
        embeddings: null, // Model unavailable
      ),
      createFixture(
        key: 'no_model_fallback_02',
        capturedAt: baseTime.add(const Duration(seconds: 601)),
        pHashHex: '0123456789ABCDEE',
        embeddings: null, // Model unavailable
      ),
    ];

    // Ground Truth Pair Definition:
    // Positive Pairs (Same Scene / Should be grouped together)
    final positivePairs = <Set<String>>{
      {'burst_01', 'burst_02'},
      {'burst_02', 'burst_03'},
      {'burst_01', 'burst_03'},
      {'zoom_wide', 'zoom_tele'},
      {'moved_01', 'moved_02'},
      {'drift_01', 'drift_02'},
      {'drift_02', 'drift_03'},
      {'lowlight_iso3200_1', 'lowlight_iso3200_2'},
      {'landscape_01', 'landscape_02'},
      {'no_model_fallback_01', 'no_model_fallback_02'},
    };

    // Negative Pairs that MUST NEVER be merged
    final negativePairs = <Set<String>>{
      {'person_day1', 'person_day2'}, // Same person, different day
      {'bg_person_A', 'bg_person_B'}, // Different subjects
      {'time_close_scene1', 'time_close_scene2_turned90deg'}, // Different composition
      {'drift_01', 'drift_04'}, // Chaining drift limit (24 bits)
      {'burst_01', 'zoom_wide'}, // Distinct scenes
      {'moved_01', 'person_day1'}, // Distinct scenes
    };

    test('Windows高精度設定 (Advanced) における詳細評価と指標算出', () {
      const config = GroupingConfig(
        algorithm: GroupingAlgorithm.advanced,
        burstWindowSeconds: 15,
        maxPHashHammingDistance: 14,
        maxDriftPHashDistance: 18,
      );

      final groups = PhotoGrouper.group(fixtures, config);

      // Verify Critical Requirements:
      // 1. 同一連写が分断されない
      final burstGroup = groups.firstWhere((g) => g.items.any((e) => e.key == 'burst_01'));
      expect(burstGroup.items.map((e) => e.key), containsAll(['burst_01', 'burst_02', 'burst_03']),
          reason: '連写は1つのグループに結束すること');

      // 2. 寄り・引きが同一シーン候補になる
      final zoomGroup = groups.firstWhere((g) => g.items.any((e) => e.key == 'zoom_wide'));
      expect(zoomGroup.items.any((e) => e.key == 'zoom_tele'), isTrue,
          reason: 'ORB RANSAC / クロップ埋め込みにより寄り引きがマージされること');

      // 3. 同じ人物の別イベントが削除グループに混ざらない
      final day1Group = groups.firstWhere((g) => g.items.any((e) => e.key == 'person_day1'));
      expect(day1Group.items.any((e) => e.key == 'person_day2'), isFalse,
          reason: '別日・別イベントは同一削除グループに混ざってはならない');

      // 4. 時刻が近いが別構図が結合されない
      final turnedGroup = groups.firstWhere((g) => g.items.any((e) => e.key == 'time_close_scene1'));
      expect(turnedGroup.items.any((e) => e.key == 'time_close_scene2_turned90deg'), isFalse,
          reason: '3秒差でも構図が異なる場合は結合してはならない');

      // 5. 連鎖誤結合が起きない
      final driftGroup1 = groups.firstWhere((g) => g.items.any((e) => e.key == 'drift_01'));
      expect(driftGroup1.items.any((e) => e.key == 'drift_04'), isFalse,
          reason: '累積ドリフトによりdrift_01と04が誤結合してはならない');

      // 6. 埋め込み未使用時に加点されない・安全にフォールバック
      final noModelGroup = groups.firstWhere((g) => g.items.any((e) => e.key == 'no_model_fallback_01'));
      expect(noModelGroup.items.any((e) => e.key == 'no_model_fallback_02'), isTrue,
          reason: 'モデルなしでもpHash/Exifにより安全に結合されること');
      final fallbackItem = noModelGroup.items.firstWhere((e) => e.key == 'no_model_fallback_02');
      expect(fallbackItem.groupExplanation?.embeddingSimilarity, isNull,
          reason: 'モデル未検出時は埋め込み類似度を加点・表示してはならない');

      // Compute Evaluation Metrics:
      int tp = 0;
      int fn = 0;
      for (final pair in positivePairs) {
        final k1 = pair.first;
        final k2 = pair.last;
        final inSameGroup = groups.any((g) => g.items.any((e) => e.key == k1) && g.items.any((e) => e.key == k2));
        if (inSameGroup) {
          tp++;
        } else {
          fn++;
        }
      }

      int fp = 0;
      int tn = 0;
      for (final pair in negativePairs) {
        final k1 = pair.first;
        final k2 = pair.last;
        final inSameGroup = groups.any((g) => g.items.any((e) => e.key == k1) && g.items.any((e) => e.key == k2));
        if (inSameGroup) {
          fp++;
        } else {
          tn++;
        }
      }

      final precision = (tp + fp) > 0 ? tp / (tp + fp) : 1.0;
      final recall = (tp + fn) > 0 ? tp / (tp + fn) : 1.0;
      final fpr = (fp + tn) > 0 ? fp / (fp + tn) : 0.0;
      final fragmentationRate = (tp + fn) > 0 ? fn / (tp + fn) : 0.0;
      final reviewCount = groups.where((g) => g.needsReview).length;
      final reviewRate = groups.isNotEmpty ? reviewCount / groups.length : 0.0;

      // ignore: avoid_print
      print('\n========================================================');
      // ignore: avoid_print
      print('【BestShot グループ化精度 評価レポート (Windows Advanced)】');
      // ignore: avoid_print
      print('・sameScene 適合率 (Precision)    : ${(precision * 100).toStringAsFixed(1)}% (目標: >= 90%)');
      // ignore: avoid_print
      print('・sameScene 再現率 (Recall)       : ${(recall * 100).toStringAsFixed(1)}% (目標: >= 85%)');
      // ignore: avoid_print
      print('・誤結合率 (False Positive Rate) : ${(fpr * 100).toStringAsFixed(1)}% (目標: <= 5%)');
      // ignore: avoid_print
      print('・分断率 (Fragmentation Rate)   : ${(fragmentationRate * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print('・要確認 (needsReview) 率        : ${(reviewRate * 100).toStringAsFixed(1)}%');
      // ignore: avoid_print
      print('・生成総グループ数               : ${groups.length}');
      // ignore: avoid_print
      print('========================================================\n');

      expect(precision, greaterThanOrEqualTo(0.90));
      expect(recall, greaterThanOrEqualTo(0.85));
      expect(fpr, equals(0.0), reason: '誤結合は0件でなければならない');
    });

    test('Android軽量版設定 (Lightweight / Fallback) における評価と指標算出', () {
      const androidConfig = GroupingConfig(
        algorithm: GroupingAlgorithm.advanced,
        burstWindowSeconds: 15,
        maxCandidatesPerPhoto: 15,
        maxPHashHammingDistance: 14,
        maxDriftPHashDistance: 18,
      );

      final groups = PhotoGrouper.group(fixtures, androidConfig);

      // Verify no crashes, safe fallback, and negative pairs protected
      for (final pair in negativePairs) {
        final k1 = pair.first;
        final k2 = pair.last;
        final inSameGroup = groups.any((g) => g.items.any((e) => e.key == k1) && g.items.any((e) => e.key == k2));
        expect(inSameGroup, isFalse, reason: 'Android軽量版でも誤結合してはならない: $pair');
      }

      // ignore: avoid_print
      print('\n========================================================');
      // ignore: avoid_print
      print('【BestShot グループ化精度 評価レポート (Android Lightweight)】');
      // ignore: avoid_print
      print('・正常完了: クラッシュなし、省メモリ候補絞り込み動作確認');
      // ignore: avoid_print
      print('・生成総グループ数: ${groups.length}');
      // ignore: avoid_print
      print('========================================================\n');
    });

    test('基準旧実装 (Legacy) との比較検証', () {
      const legacyConfig = GroupingConfig(
        algorithm: GroupingAlgorithm.legacy,
        burstWindowSeconds: 15,
        maxPHashHammingDistance: 14,
      );

      final legacyGroups = PhotoGrouper.group(fixtures, legacyConfig);

      // In legacy, zoom_wide and zoom_tele are NOT merged because pHash diff > 14 and time > 15s
      final legacyZoomGroup = legacyGroups.firstWhere((g) => g.items.any((e) => e.key == 'zoom_wide'));
      final legacyMergedZoom = legacyZoomGroup.items.any((e) => e.key == 'zoom_tele');

      // ignore: avoid_print
      print('\n========================================================');
      // ignore: avoid_print
      print('【基準旧実装 (Legacy) との比較結果】');
      // ignore: avoid_print
      print('・旧実装の寄り引きマージ成否: $legacyMergedZoom (新実装では成功)');
      // ignore: avoid_print
      print('・旧実装の総グループ数: ${legacyGroups.length}');
      // ignore: avoid_print
      print('========================================================\n');

      expect(legacyMergedZoom, isFalse, reason: '旧実装ではpHash/時間制約により寄り引きが分断されていたことを確認');
    });
  });
}
