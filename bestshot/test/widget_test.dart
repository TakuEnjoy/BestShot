import 'package:flutter_test/flutter_test.dart';

import 'package:bestshot/src/app/bestshot_app.dart';

void main() {
  testWidgets('Smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const BestShotApp());
    expect(find.textContaining('BestShot'), findsWidgets);
  });
}
