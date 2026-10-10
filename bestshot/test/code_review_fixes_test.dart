import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/models/photo_group.dart';
import 'package:bestshot/src/screens/groups_screen.dart';
import 'package:bestshot/src/screens/group_detail_screen.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';

final Uint8List _dummyBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

PhotoEntry _createEntry(
  String key, {
  String? filePath,
  Uint8List? displayBytes,
  double sharpness = 85.0,
}) {
  return PhotoEntry(
    key: key,
    origin: PhotoOrigin.filePath,
    displayBytes: displayBytes ?? _dummyBytes,
    filePath: filePath ?? 'C:/photos/IMG_20260912_143000_$key.jpg',
    pHashHex: '0000000000000000',
    sharpness: sharpness,
    exposureScore: 0.5,
    orbRows: 0,
    orbCols: 0,
    orbBytes: Uint8List(0),
    orbKeypoints: Float32List(0),
    histogram: Uint8List(256),
    portrait: const PortraitAnalysis(
      hasFace: true,
      faceSharpness: 90.0,
      eyesClosed: false,
      bothEyesDetected: true,
    ),
    exif: ExifSummary(
      fNumber: '2.8',
      shutter: '1/250',
      iso: '100',
      capturedAt: DateTime(2026, 9, 12, 14, 30),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PhotoGroup copyWith & Invariant Tests', () {
    test('PhotoGroup.copyWith automatically reassigns bestKey if previous bestKey was removed', () {
      final e1 = _createEntry('1');
      final e2 = _createEntry('2');
      final group = PhotoGroup(
        id: 'G1',
        items: [e1, e2],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
      );

      // Remove e1 (which was the bestKey) without explicitly providing bestKey
      final updated = group.copyWith(items: [e2]);

      expect(updated.items.length, equals(1));
      expect(updated.bestKey, equals('2'));
      expect(updated.items.any((e) => e.key == updated.bestKey), isTrue);
    });

    test('PhotoGroup.copyWith retains bestKey if it is still present in items', () {
      final e1 = _createEntry('1');
      final e2 = _createEntry('2');
      final group = PhotoGroup(
        id: 'G1',
        items: [e1, e2],
        bestKey: '2',
        deleteCandidateKeys: const [],
        isBurst: true,
      );

      final updated = group.copyWith(items: [e2]);
      expect(updated.bestKey, equals('2'));
    });
  });

  group('GroupDetailScreen Dynamic Best Shot State Tests', () {
    testWidgets('Pressing key B updates Best Shot badge immediately in GroupDetailScreen', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final e1 = _createEntry('1', sharpness: 70);
      final e2 = _createEntry('2', sharpness: 95);
      final group = PhotoGroup(
        id: 'G1',
        items: [e1, e2],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
      );

      String? newBestKey;

      await tester.pumpWidget(
        MaterialApp(
          home: GroupDetailScreen(
            group: group,
            selectedForDelete: const {},
            onToggleDelete: (_, _) {},
            loupeSelection: const [],
            onToggleLoupe: (_) {},
            onSetBest: (k) {
              newBestKey = k;
            },
            selectedSortFolders: const {},
            customFolders: const [],
            onSortFolderChanged: (_, _) {},
            processingKeys: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially e1 has the Best badge
      expect(find.text('Best'), findsOneWidget);

      // Navigate to e2 via right arrow key
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      // Press key B to promote e2 to Best
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();

      expect(newBestKey, equals('2'));
      // The grid thumbnail immediately reflects the new Best Shot badge
      expect(find.text('Best'), findsOneWidget);
    });
  });

  group('GroupsScreen Portrait Mode Selection Behavior Tests', () {
    testWidgets('Tapping photo thumbnail in Portrait mode toggles loupe comparison selection instead of delete', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final e1 = _createEntry('1');
      final e2 = _createEntry('2');
      final group = PhotoGroup(
        id: 'G1',
        items: [e1, e2],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupsScreen(
            groups: [group],
            detectionMode: DetectionMode.portrait,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find first image thumbnail
      final images = find.byType(Image);
      expect(images, findsWidgets);

      // Tap first image and wait past the double-tap disambiguation window
      await tester.tap(images.first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // It should NOT be marked for deletion (checkbox should be unchecked)
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox).first);
      expect(checkbox.value, isFalse);

      // Comparison bar should show '比較 (1/4)'
      expect(find.text('比較 (1/4)'), findsOneWidget);
    });
  });
}
