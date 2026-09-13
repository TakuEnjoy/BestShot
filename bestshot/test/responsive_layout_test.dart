import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/models/photo_group.dart';
import 'package:bestshot/src/screens/groups_screen.dart';
import 'package:bestshot/src/screens/loupe_screen.dart';
import 'package:bestshot/src/screens/group_detail_screen.dart';
import 'package:bestshot/src/screens/import_screen.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';

// Minimal 1x1 transparent PNG bytes for testing
final Uint8List _dummyBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

PhotoEntry _createEntry(String key, {String? filePath}) {
  return PhotoEntry(
    key: key,
    origin: PhotoOrigin.filePath,
    displayBytes: _dummyBytes,
    filePath: filePath ?? 'C:/photos/IMG_20260912_143000_$key.jpg',
    pHashHex: '0000000000000000',
    sharpness: 85.0,
    exposureScore: 0.5,
    orbRows: 0,
    orbCols: 0,
    orbBytes: Uint8List(0),
    orbKeypoints: Float32List(0),
    histogram: Uint8List(256),
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

  group('LoupeScreen Responsive Layout Tests', () {
    testWidgets('折りたたみスマホ展開時 (768x900) では2枚比較が左右2枚 (Row) で表示される', (tester) async {
      tester.view.physicalSize = const Size(768, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final items = [_createEntry('1'), _createEntry('2')];

      await tester.pumpWidget(
        MaterialApp(
          home: LoupeScreen(
            items: items,
            scores: const [85.0, 90.0],
            isBests: const [true, false],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LoupeScreen), findsOneWidget);

      final rowFinder = find.descendant(
        of: find.byType(LoupeScreen),
        matching: find.byWidgetPredicate((widget) {
          if (widget is Row && widget.children.length == 2) {
            return widget.children.every((child) => child is Expanded);
          }
          return false;
        }),
      );
      expect(rowFinder, findsOneWidget);
    });

    testWidgets('通常スマホ縦向き (390x844) では2枚比較が上下2枚 (Column) で表示される', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final items = [_createEntry('1'), _createEntry('2')];

      await tester.pumpWidget(
        MaterialApp(
          home: LoupeScreen(
            items: items,
            scores: const [85.0, 90.0],
            isBests: const [true, false],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final colFinder = find.descendant(
        of: find.byType(LoupeScreen),
        matching: find.byWidgetPredicate((widget) {
          if (widget is Column && widget.children.length == 2) {
            return widget.children.every((child) => child is Expanded);
          }
          return false;
        }),
      );
      expect(colFinder, findsOneWidget);
    });

    testWidgets('横長画面 (844x390) では2枚比較が左右2枚 (Row) で表示される', (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final items = [_createEntry('1'), _createEntry('2')];

      await tester.pumpWidget(
        MaterialApp(
          home: LoupeScreen(
            items: items,
            scores: const [85.0, 90.0],
            isBests: const [true, false],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rowFinder = find.descendant(
        of: find.byType(LoupeScreen),
        matching: find.byWidgetPredicate((widget) {
          if (widget is Row && widget.children.length == 2) {
            return widget.children.every((child) => child is Expanded);
          }
          return false;
        }),
      );
      expect(rowFinder, findsOneWidget);
    });
  });

  group('DeleteReviewScreen Responsive Grid Tests', () {
    testWidgets('スマホ幅 (<600dp) ではグリッドが2列 (crossAxisCount: 2) で表示される', (tester) async {
      tester.view.physicalSize = const Size(380, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final items = [_createEntry('1'), _createEntry('2'), _createEntry('3')];

      await tester.pumpWidget(
        MaterialApp(
          home: DeleteReviewScreen(
            items: items,
            onRemoveFromDelete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 2);
    });

    testWidgets('デスクトップ幅 (>=1000dp) ではグリッドが3列 (crossAxisCount: 3) で表示される', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final items = [_createEntry('1'), _createEntry('2'), _createEntry('3')];

      await tester.pumpWidget(
        MaterialApp(
          home: DeleteReviewScreen(
            items: items,
            onRemoveFromDelete: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);
    });
  });

  group('GroupDetailScreen Responsive Grid Tests', () {
    testWidgets('デスクトップ幅 (>=1000dp) ではグリッドが3列 (crossAxisCount: 3) で表示される', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupDetailScreen(
            group: group,
            selectedForDelete: const {},
            onToggleDelete: (_, _) {},
            loupeSelection: const [],
            onToggleLoupe: (_) {},
            onSetBest: (_) {},
            selectedSortFolders: const {},
            customFolders: const [],
            onSortFolderChanged: (_, _) {},
            processingKeys: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);
    });

    testWidgets('通常/スマホ幅 (<1000dp) ではグリッドが2列 (crossAxisCount: 2) で表示される', (tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupDetailScreen(
            group: group,
            selectedForDelete: const {},
            onToggleDelete: (_, _) {},
            loupeSelection: const [],
            onToggleLoupe: (_) {},
            onSetBest: (_) {},
            selectedSortFolders: const {},
            customFolders: const [],
            onSortFolderChanged: (_, _) {},
            processingKeys: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 2);
    });
  });

  group('GroupsScreen Responsive Grid Tests', () {
    testWidgets('デスクトップ大画面幅 (>=1100dp) ではグループ一覧が3列グリッドで表示される', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupsScreen(
            groups: [group],
            detectionMode: DetectionMode.standard,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);
    });

    testWidgets('デスクトップ中画面幅 (750dp〜1099dp) ではグループ一覧が2列グリッドで表示される', (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupsScreen(
            groups: [group],
            detectionMode: DetectionMode.standard,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 2);
    });

    testWidgets('スマホ幅 (<750dp) ではグループ一覧が1列ListViewで表示される', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupsScreen(
            groups: [group],
            detectionMode: DetectionMode.standard,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ListView), findsOneWidget);
    });
  });

  group('GroupDetailScreen Overflow Protection Tests', () {
    testWidgets('狭いスマホ画面 (360x740) で長いファイル名や情報行があってもオーバーフローエラーが発生しない', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final entry1 = _createEntry(
        'entry1',
        filePath: 'C:/very_long_directory_path/IMG_20260912_143000_super_long_filename.JPG',
      );
      final entry2 = _createEntry(
        'entry2',
        filePath: 'C:/very_long_directory_path/IMG_20260912_143001_super_long_filename.JPG',
      );

      final group = PhotoGroup(
        id: '999999',
        items: [entry1, entry2],
        bestKey: 'entry1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupDetailScreen(
            group: group,
            selectedForDelete: const {},
            onToggleDelete: (_, _) {},
            loupeSelection: const [],
            onToggleLoupe: (_) {},
            onSetBest: (_) {},
            selectedSortFolders: const {},
            customFolders: const [],
            onSortFolderChanged: (_, _) {},
            processingKeys: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('ImportScreen Pro Workstation Layout Tests', () {
    testWidgets('デスクトップ大画面幅 (1200x800) でPhotoLab/Adobe風の2カラムワークステーションUIが正常に描画される', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: ImportScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('BestShot'), findsOneWidget);
      expect(find.text('PRO'), findsOneWidget);
      expect(find.text('CULLING & BEST SHOT WORKSTATION'), findsOneWidget);
      expect(find.text('PIPELINE CONFIGURATION'), findsOneWidget);
      expect(find.text('ANALYSIS PIPELINE SPECIFICATIONS'), findsOneWidget);
      expect(find.text('Multi-Isolate Pipeline'), findsOneWidget);
    });

    testWidgets('スマホ幅 (390x844) でもオーバーフローエラーが発生せず正常に描画される', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: ImportScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('BestShot'), findsOneWidget);
      expect(find.text('PIPELINE CONFIGURATION'), findsOneWidget);
    });

    testWidgets('連写判定時間窓のプリセットチップやバッチ上限の選択が正常に反映される', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: ImportScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // 初期値は15秒
      expect(find.text('15 秒'), findsOneWidget);

      // 5秒チップをタップ
      await tester.tap(find.text('5秒 (連写)'));
      await tester.pumpAndSettle();

      expect(find.text('5 秒'), findsOneWidget);

      // 30秒チップをタップ
      await tester.tap(find.text('30秒 (長連写)'));
      await tester.pumpAndSettle();

      expect(find.text('30 秒'), findsOneWidget);
    });
  });

  group('Photo Click & Delete Trigger Strictness Tests', () {
    testWidgets('GroupsScreen: 写真タイル本体をクリックすると自動遷移せず選択され、比較ボタンまたはルーペボタンで画面遷移する', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupsScreen(
            groups: [group],
            detectionMode: DetectionMode.standard,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 画像サムネイルを見つける
      final images = find.byType(Image);
      expect(images, findsWidgets);

      // 1枚目の写真タイル本体をタップ（クリックで選択）
      await tester.tap(images.first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // 自動遷移はせず、LoupeScreenは開いていないこと
      expect(find.byType(LoupeScreen), findsNothing);

      // 選択状態になり、「比較 (1/4)」ボタンが表示されること
      final compareBtn = find.text('比較 (1/4)');
      expect(compareBtn, findsOneWidget);

      // 「比較 (1/4)」ボタンをタップして初めて画面遷移すること
      await tester.tap(compareBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(LoupeScreen), findsOneWidget);
    });

    testWidgets('GroupsScreen: 写真タイル右上のチェックボックスをクリックした時のみ削除候補に追加される', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GroupsScreen(
            groups: [group],
            detectionMode: DetectionMode.standard,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 右上のチェックボックスを探す
      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsWidgets);
      // 1枚目のチェックボックスをタップ
      await tester.tap(checkboxes.first);
      await tester.pumpAndSettle();

      // LoupeScreenには遷移せず、削除予定バッジまたはチェック状態が反映される
      expect(find.byType(LoupeScreen), findsNothing);
      expect(tester.widget<Checkbox>(checkboxes.first).value, isTrue);
    });

    testWidgets('GroupDetailScreen: サムネイルタップは削除トグルにならず、右上の削除ボタンでのみ削除トグルされる', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      String? toggledKey;
      bool? toggledVal;

      await tester.pumpWidget(
        MaterialApp(
          home: GroupDetailScreen(
            group: group,
            selectedForDelete: const {},
            onToggleDelete: (key, val) {
              toggledKey = key;
              toggledVal = val;
            },
            loupeSelection: const [],
            onToggleLoupe: (_) {},
            onSetBest: (_) {},
            selectedSortFolders: const {},
            customFolders: const [],
            onSortFolderChanged: (_, _) {},
            processingKeys: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // サムネイル画像のタップ
      final images = find.byType(Image);
      expect(images, findsWidgets);

      await tester.tap(images.first);
      await tester.pumpAndSettle();

      // 削除トグルコールバックは発火していないこと
      expect(toggledKey, isNull);

      // 右上の削除アイコン (delete_outline) をタップ
      final deleteIcons = find.byIcon(Icons.delete_outline);
      expect(deleteIcons, findsWidgets);

      await tester.tap(deleteIcons.first);
      await tester.pumpAndSettle();

      // 右上タップにより削除トグルコールバックが発火すること
      expect(toggledKey, '1');
      expect(toggledVal, isTrue);
    });

    testWidgets('GroupDetailScreen: Space / D キーで現在アクティブ写真の削除がトグルされる', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final group = PhotoGroup(
        id: '1',
        items: [_createEntry('1'), _createEntry('2')],
        bestKey: '1',
        deleteCandidateKeys: const [],
        isBurst: true,
        needsReview: false,
      );

      String? toggledKey;
      bool? toggledVal;

      await tester.pumpWidget(
        MaterialApp(
          home: GroupDetailScreen(
            group: group,
            selectedForDelete: const {},
            onToggleDelete: (key, val) {
              toggledKey = key;
              toggledVal = val;
            },
            loupeSelection: const [],
            onToggleLoupe: (_) {},
            onSetBest: (_) {},
            selectedSortFolders: const {},
            customFolders: const [],
            onSortFolderChanged: (_, _) {},
            processingKeys: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // キーボードの D キーを押す
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();

      expect(toggledKey, '1');
      expect(toggledVal, isTrue);
    });
  });
}
