import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/models/photo_group.dart';
import 'package:bestshot/src/services/deleting/delete_service.dart';
import 'package:bestshot/src/services/analysis/analyzer_isolate.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('[P0 & P1] DeleteService & DeleteResult tests', () {
    test('DeleteResult correctly reports success and failure states', () {
      const emptyResult = DeleteResult();
      expect(emptyResult.isAllSuccess, isTrue);

      final dummyEntry = PhotoEntry(
        key: 'test1',
        origin: PhotoOrigin.filePath,
        displayBytes: Uint8List(0),
        filePath: 'C:/dummy/test1.jpg',
        pHashHex: '0000000000000000',
        sharpness: 10,
        exposureScore: 0.5,
        orbRows: 0,
        orbCols: 0,
        orbBytes: Uint8List(0),
        orbKeypoints: Float32List(0),
        histogram: Uint8List(256),
      );

      final successResult = DeleteResult(success: [dummyEntry]);
      expect(successResult.isAllSuccess, isTrue);

      final failedResult = DeleteResult(failed: [dummyEntry]);
      expect(failedResult.isAllSuccess, isFalse);

      final partialResult = DeleteResult(success: [dummyEntry], unprocessed: [dummyEntry]);
      expect(partialResult.isAllSuccess, isFalse);
    });

    test('Windows path > 259 chars fails safely without falling back to File.delete()', () async {
      // Create a temporary file
      final tempDir = Directory.systemTemp.createTempSync('delete_test');
      try {
        final longName = 'a' * 260;
        final longPath = '${tempDir.path}/$longName.jpg';

        final entry = PhotoEntry(
          key: 'long_path_entry',
          origin: PhotoOrigin.filePath,
          displayBytes: Uint8List(0),
          filePath: longPath,
          pHashHex: '0000000000000000',
          sharpness: 10,
          exposureScore: 0.5,
          orbRows: 0,
          orbCols: 0,
          orbBytes: Uint8List(0),
          orbKeypoints: Float32List(0),
          histogram: Uint8List(256),
        );

        final result = await DeleteService.moveToTrash([entry]);
        expect(result.isAllSuccess, isFalse);
        expect(result.failed.length, equals(1));
        expect(result.failed.first.key, equals('long_path_entry'));
        expect(result.errorMessage, contains('MAX_PATH'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('[P1] AnalyzerIsolate error types', () {
    test('AnalysisException formats message correctly', () {
      final ex = AnalysisException(
        'Test failure',
        itemKey: 'photo1',
        filePath: '/path/to/photo1.jpg',
        cause: 'Corrupted image',
      );
      expect(ex.message, equals('Test failure'));
      expect(ex.itemKey, equals('photo1'));
      expect(ex.filePath, equals('/path/to/photo1.jpg'));
      expect(ex.cause, equals('Corrupted image'));
      expect(ex.toString(), equals('Test failure'));
    });
  });

  group('[P1] PhotoGrouper.groupAsync tests', () {
    test('groupAsync runs in background isolate and produces valid groups', () async {
      final entry1 = PhotoEntry(
        key: 'photo1',
        origin: PhotoOrigin.filePath,
        displayBytes: Uint8List(0),
        pHashHex: '1111111111111111',
        sharpness: 100,
        exposureScore: 0.8,
        orbRows: 0,
        orbCols: 0,
        orbBytes: Uint8List(0),
        orbKeypoints: Float32List(0),
        histogram: Uint8List(256),
      );
      final entry2 = PhotoEntry(
        key: 'photo2',
        origin: PhotoOrigin.filePath,
        displayBytes: Uint8List(0),
        pHashHex: 'ffffffffffffffff',
        sharpness: 90,
        exposureScore: 0.7,
        orbRows: 0,
        orbCols: 0,
        orbBytes: Uint8List(0),
        orbKeypoints: Float32List(0),
        histogram: Uint8List(256),
      );

      final groups = await PhotoGrouper.groupAsync(
        [entry1, entry2],
        const GroupingConfig(),
      );

      expect(groups, isA<List<PhotoGroup>>());
      expect(groups.isNotEmpty, isTrue);
    });
  });
}
