import 'package:bestshot/src/app/bestshot_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final layout in [
    (
      name: 'iPhone compact',
      window: const Size(320, 740),
      display: const Size(390, 844),
      cache: 96,
    ),
    (
      name: 'iPhone landscape',
      window: const Size(844, 390),
      display: const Size(844, 390),
      cache: 96,
    ),
    (
      name: 'iPad full screen',
      window: const Size(1024, 1366),
      display: const Size(1024, 1366),
      cache: 192,
    ),
    (
      name: 'iPad narrow split view',
      window: const Size(320, 1024),
      display: const Size(1024, 1366),
      cache: 192,
    ),
  ]) {
    testWidgets('${layout.name} keeps import controls and memory budget', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = layout.window;
      tester.view.display.devicePixelRatio = 1;
      tester.view.display.size = layout.display;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      await tester.pumpWidget(const BestShotApp());
      await tester.pumpAndSettle();

      expect(find.text('写真ライブラリから読み込む'), findsOneWidget);
      expect(find.text('フォルダーを選択'), findsOneWidget);
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        layout.cache * 1024 * 1024,
      );

      tester.binding.handleMemoryPressure();
      await tester.pump();
      expect(find.byType(BestShotApp), findsOneWidget);
    });
  }
}
