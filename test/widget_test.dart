import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smart_automix/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app starts on the dashboard with demo machines', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Facility Overview'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Control'), findsOneWidget);
    expect(find.text('Energy'), findsOneWidget);
    expect(find.text('Tariff'), findsOneWidget);
    expect(find.text('Air Compressor'), findsWidgets);
  });
}
