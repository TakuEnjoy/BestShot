import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';

PhotoEntry createMockEntry({
  required String key,
  required DateTime capturedAt,
  required String pHashHex,
  double sharpness = 100.0,
  Float32List? hueHistogram,
  int orbRows = 0,
  Uint8List? orbBytes,
}) {
  return PhotoEntry(
    key: key,
    origin: PhotoOrigin.filePath,
    filePath: '/mock/$key.jpg',
    displayBytes: Uint8List(0),
    pHashHex: pHashHex,
    sharpness: sharpness,
    exposureScore: 0.8,
    orbRows: orbRows,
    orbCols: orbRows > 0 ? 32 : 0,
    orbBytes: orbBytes ?? Uint8List(0),
    histogram: Uint8List(256),
    hueHistogram: hueHistogram ?? Float32List(180),
    exif: ExifSummary(
      fNumber: null,
      shutter: null,
      iso: null,
      capturedAt: capturedAt,
    ),
  );
}

void main() {
  group('PhotoGrouper Accuracy & Anti-Drift Tests', () {
    const config = GroupingConfig(
      burstWindowSeconds: 15,
      maxPHashHammingDistance: 14,
      maxDriftPHashDistance: 18,
    );

    test('シナリオ1: 0.2秒間隔の高速連写は1つのグループに結束する', () {
      final baseTime = DateTime(2026, 9, 6, 12, 0, 0);
      final items = [
        createMockEntry(
          key: 'burst_1',
          capturedAt: baseTime,
          pHashHex: '1000000000000000',
        ),
        createMockEntry(
          key: 'burst_2',
          capturedAt: baseTime.add(const Duration(milliseconds: 200)),
          pHashHex: '1000000000000001', // 1 bit diff
        ),
        createMockEntry(
          key: 'burst_3',
          capturedAt: baseTime.add(const Duration(milliseconds: 400)),
          pHashHex: '1000000000000003', // 2 bits diff
        ),
      ];

      final groups = PhotoGrouper.group(items, config);

      expect(groups.length, equals(1));
      expect(groups.first.items.length, equals(3));
      expect(groups.first.isBurst, isTrue);
    });

    test('シナリオ2: 時間判定の是正（8秒差で構図が異なる場合は別グループに分離される）', () {
      final baseTime = DateTime(2026, 9, 6, 12, 0, 0);
      // 8秒差（15秒以内）。旧ロジックでは無条件に1グループ化されていたケース
      final items = [
        createMockEntry(
          key: 'scene_a',
          capturedAt: baseTime,
          pHashHex: '1000000000000000',
        ),
        createMockEntry(
          key: 'scene_b_diff_comp',
          capturedAt: baseTime.add(const Duration(seconds: 8)),
          pHashHex: '1000000000FFFFFF', // 24 bits diff (構図が全く異なる)
        ),
      ];

      final groups = PhotoGrouper.group(items, config);

      expect(groups.length, equals(2), reason: '構図が異なるため15秒以内でも別グループになるべき');
      expect(groups[0].items.first.key, equals('scene_a'));
      expect(groups[1].items.first.key, equals('scene_b_diff_comp'));
    });

    test('シナリオ3: 芋づる連鎖（累積ドリフト）の防止', () {
      final baseTime = DateTime(2026, 9, 6, 12, 0, 0);
      // A-B, B-C, C-D はそれぞれ隣接コマ間で pHash差が 7〜8（類似範囲）
      // しかし A と D は pHash差が 24 となり全く異なる構図
      final items = [
        createMockEntry(
          key: 'frame_1',
          capturedAt: baseTime,
          pHashHex: '1000000000000000',
        ),
        createMockEntry(
          key: 'frame_2',
          capturedAt: baseTime.add(const Duration(seconds: 2)),
          pHashHex: '100000000000007F', // 7 bits from frame_1
        ),
        createMockEntry(
          key: 'frame_3',
          capturedAt: baseTime.add(const Duration(seconds: 4)),
          pHashHex: '1000000000003FFF', // 14 bits from frame_1, 7 bits from frame_2
        ),
        createMockEntry(
          key: 'frame_4',
          capturedAt: baseTime.add(const Duration(seconds: 6)),
          pHashHex: '1000000000FFFFFF', // 24 bits from frame_1, 10 bits from frame_3
        ),
      ];

      final groups = PhotoGrouper.group(items, config);

      // 旧Union-Findでは 1 グループになっていたが、アンカードリフト制御により
      // 1グループに肥大化せず適切に分割される
      expect(groups.length, greaterThanOrEqualTo(2), reason: '先頭コマから24ビット乖離したコマは別グループに分割されるべき');
      expect(groups.any((g) => g.items.any((e) => e.key == 'frame_1') && g.items.any((e) => e.key == 'frame_4')), isFalse,
          reason: 'frame_1とframe_4は同一グループに入ってはならない');
    });

    test('シナリオ4: ズーム撮り直し（色差大＋ORB高一致）の救済マージとXAI根拠の検証', () {
      final baseTime = DateTime(2026, 9, 6, 12, 0, 0);

      // Create synthetic ORB descriptors (30 rows of 32 bytes)
      final orb = Uint8List(30 * 32);
      for (var i = 0; i < orb.length; i++) {
        orb[i] = i % 256;
      }

      final items = [
        createMockEntry(
          key: 'shot_zoom_wide',
          capturedAt: baseTime,
          pHashHex: '1234567890ABCDEF',
          sharpness: 3000.0,
          orbRows: 30,
          orbBytes: orb,
        ),
        // A different intervening shot
        createMockEntry(
          key: 'shot_other_scene',
          capturedAt: baseTime.add(const Duration(seconds: 15)),
          pHashHex: 'FFFFFFFFFFFFFFFF',
          sharpness: 1000.0,
        ),
        // Re-shot with zoom (42s later, same ORB descriptors, different pHash/color)
        createMockEntry(
          key: 'shot_zoom_tele',
          capturedAt: baseTime.add(const Duration(seconds: 42)),
          pHashHex: '1234567890AA0000', // pHash diff ~16
          sharpness: 2500.0,
          orbRows: 30,
          orbBytes: orb,
        ),
      ];

      final groups = PhotoGrouper.group(items, config);

      // shot_zoom_wide and shot_zoom_tele should be post-merged together!
      final mergedGroup = groups.firstWhere(
        (g) => g.items.any((e) => e.key == 'shot_zoom_wide'),
      );

      expect(mergedGroup.items.any((e) => e.key == 'shot_zoom_tele'), isTrue,
          reason: 'ORB 30点一致によりズーム撮り直しがマージされるべき');
      expect(mergedGroup.bestKey, equals('shot_zoom_wide'),
          reason: '鮮鋭度が高い shot_zoom_wide がベストに選出されるべき');

      // Check explanations
      final wideEntry = mergedGroup.items.firstWhere((e) => e.key == 'shot_zoom_wide');
      final teleEntry = mergedGroup.items.firstWhere((e) => e.key == 'shot_zoom_tele');

      expect(wideEntry.scoreExplanation, isNotNull);
      expect(wideEntry.scoreExplanation!.normalizedSharpness, equals(1.0));
      expect(teleEntry.scoreExplanation, isNotNull);
      expect(teleEntry.scoreExplanation!.normalizedSharpness, closeTo(2500.0 / 3000.0, 0.01));

      expect(teleEntry.groupExplanation, isNotNull);
      expect(teleEntry.groupExplanation!.matchType, equals('特徴点救済マージ'));
      expect(teleEntry.groupExplanation!.orbMatches, equals(30));
    });
  });
}
