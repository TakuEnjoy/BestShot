import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide group;
import 'package:image/image.dart' as img;
import 'package:bestshot/src/models/photo_entry.dart';
import 'package:bestshot/src/models/review_session.dart';
import 'package:bestshot/src/screens/review_tools_screen.dart';
import 'package:bestshot/src/screens/group_detail_screen.dart';
import 'package:bestshot/src/screens/groups_screen.dart';
import 'package:bestshot/src/services/analysis/analysis_types.dart';
import 'grouping_modes_test.dart' show photo;
import 'review_session_test.dart' show group;

final png = Uint8List.fromList(img.encodePng(img.Image(1, 1)));
PhotoEntry entry(String key) =>
    photo(key).copyWith(displayBytes: png, filePath: () => '/photos/$key.jpg');
void size(WidgetTester tester, Size value) {
  tester.view.physicalSize = value;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('manual edits survive underlying viewer rebuild and return', (
    tester,
  ) async {
    size(tester, const Size(1280, 900));
    final session = ReviewSession(
      groups: [
        group('g', [entry('a'), entry('b')]),
      ],
      mode: DetectionMode.standard,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GroupsScreen(
          groups: session.groups,
          detectionMode: session.mode,
          reviewSession: session,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('選別・グループ編集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('g'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.tap(find.text('選択写真を分割'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(session.groups.length, 2);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(session.groups.length, 2);
    expect(find.text('g・分割'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'review editor supports status, protection, rename, split, merge at mobile width',
    (tester) async {
      size(tester, const Size(320, 800));
      final session = ReviewSession(
        groups: [
          group('g', [entry('a'), entry('b')]),
        ],
        mode: DetectionMode.standard,
      );
      await tester.pumpWidget(
        MaterialApp(home: ReviewToolsScreen(session: session)),
      );
      await tester.tap(find.text('g'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('保護').first);
      await tester.pumpAndSettle();
      expect(session.protectedKeys, {'a'});
      await tester.tap(find.byType(PopupMenuButton<PhotoDecision>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('残す').last);
      await tester.pumpAndSettle();
      expect(session.decisions['a'], PhotoDecision.keep);
      await tester.tap(find.text('確認済み'));
      await tester.pumpAndSettle();
      expect(session.reviewedGroupIds, {'g'});
      await tester.tap(find.text('名前変更'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '人物A');
      await tester.tap(find.text('変更'));
      await tester.pumpAndSettle();
      expect(session.groupNames['g'], '人物A');
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.tap(find.text('選択写真を分割'));
      await tester.pumpAndSettle();
      expect(session.groups.length, 2);
      expect(session.reviewedGroupIds, isEmpty);
      // Select the two group checkboxes (not photo checkboxes).
      for (final tile in tester.widgetList<ExpansionTile>(
        find.byType(ExpansionTile),
      )) {
        (tile.leading! as Checkbox).onChanged!(true);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('結合'));
      await tester.pumpAndSettle();
      expect(session.groups.length, 1);
      expect(session.groups.single.items.length, 2);
      expect(session.protectedKeys, {'a'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail sort preserves active photo and best; protection vetoes bulk and keys',
    (tester) async {
      size(tester, const Size(1280, 900));
      final g = group('g', [entry('b'), entry('a'), entry('c')]);
      final session = ReviewSession(groups: [g], mode: DetectionMode.standard)
        ..photoOrder = PhotoOrder.filename;
      final deletion = ValueNotifier<Set<String>>({});
      addTearDown(deletion.dispose);
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: GroupDetailScreen(
            group: g,
            reviewSession: session,
            selectedForDelete: const {},
            selectedForDeleteNotifier: deletion,
            onToggleDelete: (key, value) {
              selected = key;
            },
            onUpdateDeleteSelection: (keys) => deletion.value = keys,
            loupeSelection: const [],
            onToggleLoupe: (_) {},
            selectedSortFolders: const {},
            customFolders: const [],
            processingKeys: const {},
            onSortFolderChanged: (_, _) {},
            onSetBest: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<PhotoOrder>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ファイル名・降順').last);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(g.bestKey, 'b');
      expect(deletion.value, {'b'});
      session.setProtected('a', true);
      session.setDecision('c', PhotoDecision.hold);
      await tester.tap(find.text('Best抽出'));
      await tester.pumpAndSettle();
      expect(deletion.value, isEmpty);
      session.setProtected('b', true);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(deletion.value, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'portrait resume and reordering preserve active key for best action',
    (tester) async {
      size(tester, const Size(1500, 900));
      final session =
          ReviewSession(
              groups: [
                group('g', [entry('a'), entry('b')]),
              ],
              mode: DetectionMode.portrait,
            )
            ..photoOrder = PhotoOrder.filename
            ..activeKey = 'b';
      await tester.pumpWidget(
        MaterialApp(
          home: GroupsScreen(
            groups: session.groups,
            detectionMode: session.mode,
            reviewSession: session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<PhotoOrder>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ファイル名・降順').last);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();
      expect(session.groups.single.bestKey, 'b');
      expect(session.photoOrder, PhotoOrder.filenameDescending);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('normal filtered keyboard actions cannot modify hidden groups', (
    tester,
  ) async {
    size(tester, const Size(1500, 900));
    final session =
        ReviewSession(
            groups: [
              group('hidden', [entry('a')]),
              group('visible', [entry('b')]),
            ],
            mode: DetectionMode.standard,
          )
          ..unreviewedOnly = true
          ..activeKey = 'a';
    session.reviewedGroupIds.add('hidden');
    await tester.pumpWidget(
      MaterialApp(
        home: GroupsScreen(
          groups: session.groups,
          detectionMode: session.mode,
          reviewSession: session,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    final selections = tester
        .widgetList<ValueListenableBuilder<Set<String>>>(
          find.byType(ValueListenableBuilder<Set<String>>),
        )
        .map((w) => w.valueListenable.value);
    expect(selections, isNotEmpty);
    expect(
      selections.every((keys) => keys.contains('b') && !keys.contains('a')),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
