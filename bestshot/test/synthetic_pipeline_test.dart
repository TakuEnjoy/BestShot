import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/importing/import_service.dart';
import 'package:bestshot/src/services/analysis/analyzer_isolate.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Synthetic End-to-End Pipeline Tests (CI Standalone)', () {
    late Directory tempDir;
    late File fileA1;
    late File fileA2;
    late File fileB1;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bestshot_synthetic_ci_');

      final red = img.getColor(220, 40, 40);
      final blue = img.getColor(30, 80, 240);
      final green = img.getColor(30, 200, 50);
      final yellow = img.getColor(240, 230, 30);

      // Image A1: Red background with a blue circle
      final imageA1 = img.Image(200, 200);
      img.fill(imageA1, red);
      img.fillCircle(imageA1, 100, 100, 30, blue);

      // Image A2: Slightly shifted burst of Image A1
      final imageA2 = img.Image(200, 200);
      img.fill(imageA2, red);
      img.fillCircle(imageA2, 103, 101, 30, blue);

      // Image B1: Completely different scene (green background with yellow rectangle)
      final imageB1 = img.Image(200, 200);
      img.fill(imageB1, green);
      img.fillRect(imageB1, 40, 40, 160, 160, yellow);

      fileA1 = File(p.join(tempDir.path, 'burst_sceneA_01.jpg'))..writeAsBytesSync(img.encodeJpg(imageA1));
      fileA2 = File(p.join(tempDir.path, 'burst_sceneA_02.jpg'))..writeAsBytesSync(img.encodeJpg(imageA2));
      fileB1 = File(p.join(tempDir.path, 'sceneB_01.jpg'))..writeAsBytesSync(img.encodeJpg(imageB1));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Full import -> analyze -> groupAsync pipeline on synthetic files', () async {
      final files = [fileA1, fileA2, fileB1];

      // 1. Import
      final imported = await ImportService.importSelectedFiles(
        files,
        thumbnailMaxEdge: 256,
      );
      expect(imported.length, equals(3));

      // 2. Analyze with AnalyzerIsolate
      final analyzed = await AnalyzerIsolate.analyzeAll(
        imported.map((e) => e.toAnalyzeInput()).toList(),
        mode: DetectionMode.standard,
      );
      expect(analyzed.length, equals(3));

      final byKey = {for (final a in analyzed) a.key: a};
      final entries = <PhotoEntry>[];
      for (final i in imported) {
        final a = byKey[i.key];
        if (a == null) continue;
        entries.add(
          PhotoEntry(
            key: p.basename(i.filePath ?? i.key),
            origin: i.origin,
            displayBytes: i.displayBytes,
            filePath: i.filePath,
            pHashHex: a.pHashHex,
            sharpness: a.sharpness,
            exposureScore: a.exposureScore,
            orbRows: a.orbRows,
            orbCols: a.orbCols,
            orbBytes: a.orbBytes,
            orbKeypoints: a.orbKeypoints,
            histogram: a.histogram,
            hueHistogram: a.hueHistogram,
            exif: i.exifSummary,
          ),
        );
      }

      // 3. Asynchronous Grouping
      final groups = await PhotoGrouper.groupAsync(
        entries,
        const GroupingConfig(burstWindowSeconds: 15),
      );

      expect(groups.length, equals(2));

      final groupA = groups.firstWhere(
        (g) => g.items.any((e) => e.key == 'burst_sceneA_01.jpg'),
      );
      final namesA = groupA.items.map((e) => e.key).toList()..sort();
      expect(namesA, equals(['burst_sceneA_01.jpg', 'burst_sceneA_02.jpg']));

      final groupB = groups.firstWhere(
        (g) => g.items.any((e) => e.key == 'sceneB_01.jpg'),
      );
      expect(groupB.items.length, equals(1));
      expect(groupB.items.first.key, equals('sceneB_01.jpg'));
    });
  });
}
