// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/services/importing/import_service.dart';
import 'package:bestshot/src/services/analysis/analyzer_isolate.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';
import 'package:path/path.dart' as p;

void main() {
  final testDirPath = Platform.environment['BESTSHOT_TEST_DIR'] ?? r'C:\Users\makww\Documents\AiProjects\Test';
  final dir = Directory(testDirPath);
  final isAvailable = dir.existsSync();

  test(
    'Full pipeline test on all 39 test images',
    () async {
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      expect(files.length, equals(39));

    print('Step 1: Importing files with ImportService...');
    final imported = await ImportService.importSelectedFiles(
      files,
      thumbnailMaxEdge: 512,
    );
    print('Imported ${imported.length} items.');

    print('Step 2: Analyzing with AnalyzerIsolate...');
    final analyzed = await AnalyzerIsolate.analyzeAll(
      imported.map((e) => e.toAnalyzeInput()).toList(),
      mode: DetectionMode.standard,
    );
    print('Analyzed ${analyzed.length} items.');

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

    print('\nStep 3: Grouping with PhotoGrouper...');
    final groups = PhotoGrouper.group(entries, const GroupingConfig());

    print('\n================ PRODUCTION FULL PIPELINE RESULTS ================');
    print('Total groups formed: ${groups.length} (Expected: 20)');
    for (int i = 0; i < groups.length; i++) {
      final g = groups[i];
      final names = g.items.map((e) => e.key).toList()..sort();
      print('Group #${i + 1} (${names.length} photos): ${names.join(", ")}');
    }

    expect(groups.length, equals(20));

    // Verify specifically that 81, 82, 83 are grouped together and 131, 132 are grouped together
    final group81 = groups.firstWhere((g) => g.items.any((e) => e.key == '81.jpg'));
    final names81 = group81.items.map((e) => e.key).toList()..sort();
    expect(names81, equals(['81.jpg', '82.jpg', '83.dng']));

    final group131 = groups.firstWhere((g) => g.items.any((e) => e.key == '131.jpg'));
    final names131 = group131.items.map((e) => e.key).toList()..sort();
    expect(names131, equals(['131.jpg', '132.jpg']));

    // Subset test: Only 81, 82, 83, 131, 132
    print('\nTesting subset of only 81, 82, 83, 131, 132:');
    final subsetEntries = entries.where((e) => ['81.jpg', '82.jpg', '83.dng', '131.jpg', '132.jpg'].contains(e.key)).toList();
    final subsetGroups = PhotoGrouper.group(subsetEntries, const GroupingConfig());
    print('Subset total groups: ${subsetGroups.length} (Expected: 2)');
    for (int i = 0; i < subsetGroups.length; i++) {
      final g = subsetGroups[i];
      final names = g.items.map((e) => e.key).toList()..sort();
      print('Subset Group #${i + 1} (${names.length} photos): ${names.join(", ")}');
    }
    expect(subsetGroups.length, equals(2));
    final sub81 = subsetGroups.firstWhere((g) => g.items.any((e) => e.key == '81.jpg'));
    expect(sub81.items.map((e) => e.key).toList()..sort(), equals(['81.jpg', '82.jpg', '83.dng']));
    final sub131 = subsetGroups.firstWhere((g) => g.items.any((e) => e.key == '131.jpg'));
    expect(sub131.items.map((e) => e.key).toList()..sort(), equals(['131.jpg', '132.jpg']));
  }, skip: isAvailable ? false : 'Test images directory not found at $testDirPath (set BESTSHOT_TEST_DIR to enable)');
}
