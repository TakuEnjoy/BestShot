import 'dart:io';

import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/services/deleting/ios_file_trash.dart';
import 'package:bestshot/src/services/importing/import_service.dart';
import 'package:bestshot/src/services/semantic/native_face_detector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

class TestAlbum extends AssetPathEntity {
  TestAlbum(this.assets) : super(id: 'album', name: 'Test');
  final List<AssetEntity> assets;
  @override
  Future<List<AssetEntity>> getAssetListRange({
    required int start,
    required int end,
    RequestType? type,
  }) async => assets.skip(start).take(end - start).toList();
}

class TestAsset extends AssetEntity {
  TestAsset(String id, {this.unavailable = false})
    : super(
        id: id,
        typeInt: 1,
        title: 'IMG_0001.HEIC',
        width: 4000,
        height: 3000,
        createDateSecond: 1700000000,
      );
  final bool unavailable;
  final requestedOptions = <ThumbnailOption>[];

  @override
  Future<Uint8List?> thumbnailDataWithOption(
    ThumbnailOption option, {
    PMProgressHandler? progressHandler,
    PMCancelToken? cancelToken,
  }) async {
    requestedOptions.add(option);
    return unavailable ? null : Uint8List.fromList([1, 2, 3]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'PhotoKit import preserves asset identity/date and respects batch limit',
    () async {
      final asset = TestAsset('one');
      final result = await ImportService.importAlbum(
        TestAlbum([asset, TestAsset('two')]),
        maxCount: 1,
      );
      expect(result, hasLength(1));
      expect(result.single.origin, PhotoOrigin.deviceAsset);
      expect(result.single.assetId, 'one');
      expect(result.single.originalFilename, 'IMG_0001.HEIC');
      expect(result.single.filePath, isNull);
      expect(result.single.exifSummary!.capturedAt, asset.createDateTime);
      expect(result.single.exifSummary!.imageWidth, 4000);
      expect(
        asset.requestedOptions.single.size,
        const ThumbnailSize(1920, 1920),
      );
    },
  );

  test(
    'PhotoKit cancellation stops between assets and tolerates unavailable assets',
    () async {
      var cancelled = false;
      final result = await ImportService.importAlbum(
        TestAlbum([TestAsset('offline', unavailable: true), TestAsset('two')]),
        maxCount: 2,
        onProgress: (_, _) => cancelled = true,
        isCancelled: () => cancelled,
      );
      expect(result, isEmpty);
    },
  );

  test('PhotoKit reports an error when every asset is unavailable', () async {
    await expectLater(
      ImportService.importAlbum(
        TestAlbum([TestAsset('offline', unavailable: true)]),
        maxCount: 1,
      ),
      throwsStateError,
    );
  });

  test(
    'iOS file trash preserves contents and excludes trashed photos from scans',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bestshot-trash-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/photo.jpg');
      await source.writeAsBytes([1, 2, 3]);
      await IosFileTrash.move(source);
      expect(await source.exists(), isFalse);
      final preserved = await directory
          .list(recursive: true)
          .where((f) => f is File)
          .toList();
      expect(preserved, hasLength(1));
      expect(await File(preserved.single.path).readAsBytes(), [1, 2, 3]);
      expect(
        (await ImportService.scanFolder(directory.path))!.filesByDate,
        isEmpty,
      );

      // Reusing the same filename must not overwrite an earlier trashed image.
      await source.writeAsBytes([4, 5]);
      await IosFileTrash.move(source);
      final files = await directory
          .list(recursive: true)
          .where((f) => f is File)
          .toList();
      expect(files, hasLength(2));
      expect(await File(preserved.single.path).readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'native face bridge preserves unknown eyes and accepts numeric coordinates',
    () async {
      const channel = MethodChannel('com.example.bestshot/vision');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'detectFaces');
        return [
          {
            'x': 0,
            'y': 0.2,
            'width': 0.5,
            'height': 0.6,
            'leftEyeOpenProbability': 1,
          },
        ];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final face = (await NativeFaceDetector().processImage(
        '/image.jpg',
      )).single;
      expect(face.x, 0.0);
      expect(face.leftEyeOpenProbability, 1.0);
      expect(face.rightEyeOpenProbability, isNull);
    },
  );
}
