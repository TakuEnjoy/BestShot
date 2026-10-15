import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/sorting/sort_service.dart';

void main() {
  group('SortService.validateFolderName tests', () {
    test('rejects null, empty, and whitespace strings', () {
      expect(SortService.validateFolderName(null).isValid, isFalse);
      expect(SortService.validateFolderName('').isValid, isFalse);
      expect(SortService.validateFolderName('   ').isValid, isFalse);
    });

    test('rejects path traversal and directory separators', () {
      expect(SortService.validateFolderName('.').isValid, isFalse);
      expect(SortService.validateFolderName('..').isValid, isFalse);
      expect(SortService.validateFolderName('../subfolder').isValid, isFalse);
      expect(SortService.validateFolderName('sub/folder').isValid, isFalse);
      expect(SortService.validateFolderName(r'sub\folder').isValid, isFalse);
      expect(SortService.validateFolderName('sub..folder').isValid, isFalse);
    });

    test('rejects trailing dot and trailing space', () {
      expect(SortService.validateFolderName('folder.').isValid, isFalse);
      expect(SortService.validateFolderName('myfolder.').isValid, isFalse);
    });

    test('accepts ordinary iOS folder names', () {
      for (final name in ['CON', 'AUX', 'NUL', '家族写真']) {
        expect(SortService.validateFolderName(name).isValid, isTrue);
      }
    });

    test('rejects invalid filesystem characters', () {
      for (final ch in ['<', '>', ':', '"', '|', '?', '*']) {
        final res = SortService.validateFolderName('photo${ch}test');
        expect(
          res.isValid,
          isFalse,
          reason: 'Folder with $ch must be rejected',
        );
      }
    });

    test('rejects folder names exceeding 50 characters', () {
      final longName = 'a' * 51;
      final res = SortService.validateFolderName(longName);
      expect(res.isValid, isFalse);
      expect(res.errorMessage, contains('50文字以内'));
    });

    test(
      'accepts valid folder names including Japanese and common punctuation',
      () {
        final validNames = [
          'Selected',
          '2026-09-13',
          'Burst_01',
          '家族写真',
          '旅行（沖縄）',
          'Best-Shots_#1',
        ];
        for (final name in validNames) {
          final res = SortService.validateFolderName(name);
          expect(res.isValid, isTrue, reason: '$name should be valid');
          expect(res.errorMessage, isNull);
        }
      },
    );
  });

  group('SortService.sortPhotosToCustomFolders path traversal guard', () {
    late Directory tempDir;
    late File sampleFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sort_service_test_');
      sampleFile = File(p.join(tempDir.path, 'sample.jpg'))
        ..writeAsBytesSync([1, 2, 3]);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('fails safely and rejects traversal folder targets', () async {
      final entry = PhotoEntry(
        key: 'sample',
        origin: PhotoOrigin.filePath,
        filePath: sampleFile.path,
        displayBytes: Uint8List(0),
        pHashHex: '0000000000000000',
        sharpness: 10,
        exposureScore: 0.5,
        orbRows: 0,
        orbCols: 0,
        orbBytes: Uint8List(0),
        orbKeypoints: Float32List(0),
        histogram: Uint8List(256),
      );

      final result = await SortService.executeSort(
        sortMap: {'sample': '../escaped'},
        entries: [entry],
        isCopy: true,
      );

      expect(result.successCount, equals(0));
      expect(result.failedFiles.length, equals(1));
      expect(result.failedFiles.first, equals(sampleFile.path));
    });

    test('successfully sorts into valid subfolder', () async {
      final entry = PhotoEntry(
        key: 'sample',
        origin: PhotoOrigin.filePath,
        filePath: sampleFile.path,
        displayBytes: Uint8List(0),
        pHashHex: '0000000000000000',
        sharpness: 10,
        exposureScore: 0.5,
        orbRows: 0,
        orbCols: 0,
        orbBytes: Uint8List(0),
        orbKeypoints: Float32List(0),
        histogram: Uint8List(256),
      );

      final result = await SortService.executeSort(
        sortMap: {'sample': 'ValidSubfolder'},
        entries: [entry],
        isCopy: true,
      );

      expect(result.successCount, equals(1));
      expect(result.failedFiles, isEmpty);
      expect(
        File(p.join(tempDir.path, 'ValidSubfolder', 'sample.jpg')).existsSync(),
        isTrue,
      );
    });
  });
}
