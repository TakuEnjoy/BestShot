import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/models/photo_group.dart';
import 'package:bestshot/src/models/review_session.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';
import 'package:bestshot/src/services/review_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'grouping_modes_test.dart' show photo;

ReviewSession session(List<PhotoEntry> photos) => ReviewSession(
  groups: [
    PhotoGroup(
      id: 'group',
      items: photos,
      bestKey: photos.first.key,
      deleteCandidateKeys: const [],
      isBurst: false,
      needsReview: false,
    ),
  ],
  mode: DetectionMode.standard,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.bestshot/vision');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'PhotoKit filenames determine name order and survive a saved session',
    () {
      final a = photo('asset:a').copyWith(
        origin: PhotoOrigin.deviceAsset,
        assetId: () => 'a',
        originalFilename: () => 'IMG_0200.HEIC',
        portrait: const PortraitAnalysis(
          hasFace: true,
          faceX: 120,
          faceW: 300,
          faceImageWidth: 1920,
          faceImageHeight: 1280,
        ),
      );
      final b = photo('asset:b').copyWith(
        origin: PhotoOrigin.deviceAsset,
        assetId: () => 'b',
        originalFilename: () => 'IMG_0100.HEIC',
      );
      final review = session([a, b])..photoOrder = PhotoOrder.filename;
      final restored = ReviewSessionStore.decode(
        ReviewSessionStore.encode(review),
      );
      expect(
        restored.sortedPhotos(restored.groups.single.items).map((e) => e.key),
        ['asset:b', 'asset:a'],
      );
      final first = restored.groups.single.items.first;
      expect(first.assetId, 'a');
      expect(first.filePath, isNull);
      expect(first.portrait.faceImageWidth, 1920);
      expect(first.portrait.faceImageHeight, 1280);
      expect(first.copyWith(sharpness: 200).originalFilename, 'IMG_0200.HEIC');
    },
  );

  test(
    'saving passes a complete snapshot and folder bookmarks to the iOS exporter',
    () async {
      final review = session([
        photo('photo').copyWith(filePath: () => '/Photos/photo.jpg'),
      ]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'captureFolderBookmarks') {
          return {'/Photos': 'bookmark'};
        }
        expect(call.method, 'saveReviewSession');
        final bytes = (call.arguments as Map)['bytes'] as Uint8List;
        expect(ReviewSessionStore.decode(bytes).directoryBookmarks, {
          '/Photos': 'bookmark',
        });
        return true;
      });
      expect(await ReviewSessionStore.save(review), isTrue);
    },
  );

  test(
    'reopening restores folder access and rebases moved folders without changing selection',
    () async {
      final review =
          session([
              photo('photo').copyWith(filePath: () => '/Old/Photos/photo.jpg'),
            ])
            ..activeKey = 'photo'
            ..photoOrder = PhotoOrder.newest;
      review.directoryBookmarks['/Old/Photos'] = 'bookmark';
      review.comparisonKeys.add('photo');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openReviewSession') {
          return ReviewSessionStore.encode(review);
        }
        expect(call.method, 'restoreFolderBookmarks');
        return {'/Old/Photos': '/New/Photos'};
      });
      final restored = (await ReviewSessionStore.open())!;
      expect(
        restored.groups.single.items.single.filePath,
        '/New/Photos/photo.jpg',
      );
      expect(restored.groups.single.items.single.key, 'photo');
      expect(restored.activeKey, 'photo');
      expect(restored.comparisonKeys, ['photo']);
      expect(restored.photoOrder, PhotoOrder.newest);
    },
  );

  test(
    'cancelling the iOS document picker leaves the session intact',
    () async {
      final review = session([photo('photo')]);
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await ReviewSessionStore.save(review), isFalse);
      expect(await ReviewSessionStore.open(), isNull);
      expect(review.groups.single.bestKey, 'photo');
    },
  );
}
