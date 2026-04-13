import 'package:flutter_test/flutter_test.dart';

import 'package:battleship/main.dart';

void main() {
  testWidgets('Game shell renders', (WidgetTester tester) async {
    await tester.pumpWidget(const BattleshipApp());

    expect(find.textContaining('SCORE'), findsOneWidget);
    expect(find.textContaining('P1 CONTROL'), findsOneWidget);
    expect(find.textContaining('P2 CONTROL'), findsOneWidget);
    expect(find.textContaining('Missile:'), findsNWidgets(2));
    expect(find.textContaining('Torpedo:'), findsNWidgets(2));
    expect(find.textContaining('Mine:'), findsNWidgets(2));
  });
}
