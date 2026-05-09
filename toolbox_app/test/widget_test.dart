import 'package:flutter_test/flutter_test.dart';
import 'package:toolbox_app/main.dart';

void main() {
  testWidgets('shows the Smart Tool Table inventory home', (tester) async {
    await tester.pumpWidget(const SmartToolTableApp());

    expect(find.text('Drawer Map'), findsOneWidget);
    expect(find.text('INVENTORY'), findsOneWidget);
    expect(find.text('Soldering Iron'), findsOneWidget);
  });
}
