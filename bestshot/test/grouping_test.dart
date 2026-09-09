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
  Float32List? orbKeypoints,
  String? fNumber,
  String? shutter,
  String? iso,
  String? focalLength,
  String? cameraModel,
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
    orbKeypoints: orbKeypoints ?? Float32List(0),
    histogram: Uint8List(256),
    hueHistogram: hueHistogram ?? Float32List(180),
    exif: ExifSummary(
      fNumber: fNumber,
      shutter: shutter,
      iso: iso,
      capturedAt: capturedAt,
      focalLength: focalLength,
      cameraModel: cameraModel,
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
      for (var i = 0; i < 30; i++) {
        orb[i * 32] = i;
        for (var j = 1; j < 32; j++) {
          orb[i * 32 + j] = j;
        }
      }
      
      final kps = Float32List(60);
      for (var i = 0; i < 30; i++) {
        kps[i * 2] = (i % 5) * 10.0;
        kps[i * 2 + 1] = (i ~/ 5) * 10.0;
      }

      final items = [
        createMockEntry(
          key: 'shot_zoom_wide',
          capturedAt: baseTime,
          pHashHex: '1234567890ABCDEF',
          sharpness: 3000.0,
          orbRows: 30,
          orbBytes: orb,
          orbKeypoints: kps,
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
          orbKeypoints: kps,
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

    test('シナリオ5: 望遠連写（同一EXIF＋局所一致＋pHash近傍）の3枚結束検証（0077, 0078, 0079パターン）', () {
      final baseTime = DateTime(2026, 9, 6, 15, 27, 42);
      final orbA = Uint8List(10 * 32);
      final orbB = Uint8List(10 * 32);
      final orbC = Uint8List(10 * 32);
      final kps = Float32List(10 * 2);

      // 5 shared keypoints forming a 2D polygon (non-collinear)
      final pts = [
        [50.0, 50.0],
        [200.0, 50.0],
        [200.0, 200.0],
        [50.0, 200.0],
        [125.0, 125.0],
      ];
      for (int i = 0; i < 5; i++) {
        for (int b = 0; b < 32; b++) {
          final val = (i * 23 + b * 7 + 1) & 0xFF;
          orbA[i * 32 + b] = val;
          orbB[i * 32 + b] = val;
          orbC[i * 32 + b] = val;
        }
        kps[i * 2] = pts[i][0];
        kps[i * 2 + 1] = pts[i][1];
      }
      for (int i = 5; i < 10; i++) {
        for (int b = 0; b < 32; b++) {
          orbA[i * 32 + b] = (i * 31 + b * 11 + 3) & 0xFF;
          orbB[i * 32 + b] = (i * 47 + b * 13 + 5) & 0xFF;
          orbC[i * 32 + b] = (i * 59 + b * 17 + 7) & 0xFF;
        }
        kps[i * 2] = (i * 30.0 + 10.0);
        kps[i * 2 + 1] = (i * 40.0 + 20.0);
      }

      final items = [
        createMockEntry(
          key: 'shot_tele_0077',
          capturedAt: baseTime,
          pHashHex: '90718F847B77BEBE',
          sharpness: 52.0,
          focalLength: '250 mm',
          cameraModel: 'Canon EOS Kiss X9',
          fNumber: '10',
          shutter: '1/800',
          iso: '200',
          orbRows: 10,
          orbBytes: orbA,
          orbKeypoints: kps,
        ),
        createMockEntry(
          key: 'shot_tele_0078',
          capturedAt: baseTime.add(const Duration(milliseconds: 1420)),
          pHashHex: 'D57C8297D77E7AB7', // 23 bits from 0077
          sharpness: 57.0,
          focalLength: '250 mm',
          cameraModel: 'Canon EOS Kiss X9',
          fNumber: '10',
          shutter: '1/800',
          iso: '200',
          orbRows: 10,
          orbBytes: orbB,
          orbKeypoints: kps,
        ),
        createMockEntry(
          key: 'shot_tele_0079',
          capturedAt: baseTime.add(const Duration(milliseconds: 2110)),
          pHashHex: '956F87D3D3777FBF', // 14 bits from 0078
          sharpness: 55.0,
          focalLength: '250 mm',
          cameraModel: 'Canon EOS Kiss X9',
          fNumber: '10',
          shutter: '1/800',
          iso: '200',
          orbRows: 10,
          orbBytes: orbC,
          orbKeypoints: kps,
        ),
      ];

      final groups = PhotoGrouper.group(items, config);
      expect(groups.length, equals(1), reason: '0077, 0078, 0079は同一グループに結束すること');
      expect(groups.first.items.length, equals(3));
    });

    test('シナリオ6: 連続ショットでの光学ズーム寄りと引き（0102, 0103パターン）および露出・絞り差による非結合ガード（0095, 0096パターン）', () {
      final baseTime = DateTime(2026, 9, 6, 11, 52, 28);
      final orb = Uint8List(5 * 32);
      final kps = Float32List(5 * 2);

      final items = [
        // 0102 vs 0103: 30mm -> 47mm within 1.8s, same f/9, ISO 100, 1/400s vs 1/500s
        createMockEntry(
          key: 'shot_zoom_0102',
          capturedAt: baseTime,
          pHashHex: 'DFB69D3FCC615CC7',
          focalLength: '30 mm',
          cameraModel: 'Canon EOS Kiss X9',
          fNumber: '9',
          shutter: '1/400',
          iso: '100',
          orbRows: 5,
          orbBytes: orb,
          orbKeypoints: kps,
        ),
        createMockEntry(
          key: 'shot_zoom_0103',
          capturedAt: baseTime.add(const Duration(milliseconds: 1800)),
          pHashHex: 'D881B801B0202060', // 33 bits diff
          focalLength: '47 mm',
          cameraModel: 'Canon EOS Kiss X9',
          fNumber: '9',
          shutter: '1/500',
          iso: '100',
          orbRows: 5,
          orbBytes: orb,
          orbKeypoints: kps,
        ),

        // 0095 vs 0096: 18mm -> 32mm within 1.45s, BUT f/9 vs f/8, 1/250s vs 1/400s (exposure mismatch)
        createMockEntry(
          key: 'shot_diff_0095',
          capturedAt: baseTime.add(const Duration(minutes: 30)),
          pHashHex: '8080EF18C0E03C70',
          focalLength: '18 mm',
          cameraModel: 'Canon EOS Kiss X9',
          fNumber: '9',
          shutter: '1/250',
          iso: '100',
        ),
        createMockEntry(
          key: 'shot_diff_0096',
          capturedAt: baseTime.add(const Duration(minutes: 30, milliseconds: 1450)),
          pHashHex: '86B0201FF8C0D080',
          focalLength: '32 mm',
          cameraModel: 'Canon EOS Kiss X9',
          fNumber: '8', // different fNumber
          shutter: '1/400', // different shutter
          iso: '100',
        ),
      ];

      final groups = PhotoGrouper.group(items, config);

      // 0102 and 0103 should be grouped together
      final zoomGroup = groups.firstWhere((g) => g.items.any((e) => e.key == 'shot_zoom_0102'));
      expect(zoomGroup.items.any((e) => e.key == 'shot_zoom_0103'), isTrue,
          reason: '0102と0103は寄りと引きとして同一グループに結合されること');

      // 0095 and 0096 MUST NOT be grouped together
      final g95 = groups.firstWhere((g) => g.items.any((e) => e.key == 'shot_diff_0095'));
      expect(g95.items.any((e) => e.key == 'shot_diff_0096'), isFalse,
          reason: '0095と0096は絞り・シャッター速度差により結合されてはならない');
    });
  });
}
