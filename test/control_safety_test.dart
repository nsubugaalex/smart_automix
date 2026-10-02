import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smart_automix/main.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/security_service.dart';

/// UI-level checks of the control safety rules in control_actions.dart.
void main() {
  Future<void> openControlTab(WidgetTester tester, {String? pin}) async {
    SharedPreferences.setMockInitialValues({});
    // A PIN loaded from storage (rather than just set) starts locked.
    FlutterSecureStorage.setMockInitialValues({
      if (pin != null) 'operator_pin': pin,
      'require_pin': pin != null ? 'true' : 'false',
    });
    await deviceService.init();
    await securityService.init();

    await tester.binding.setSurfaceSize(const Size(800, 1400));
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Control'));
    await tester.pumpAndSettle();
  }

  Finder switchFor(String machine) => find.descendant(
        of: find
            .ancestor(of: find.text(machine), matching: find.byType(Card))
            .last,
        matching: find.byType(Switch),
      );

  testWidgets('starting a machine asks for the PIN; stopping does not',
      (tester) async {
    await openControlTab(tester, pin: '2468');
    // Borehole Pump starts off, Grinding Machine starts on (demo data).
    expect(deviceService.getDeviceById('5')!.isOn, isFalse);
    expect(securityService.isUnlocked, isFalse);

    // Switching off while locked: no PIN prompt, takes effect immediately.
    await tester.tap(switchFor('Grinding Machine'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(deviceService.getDeviceById('1')!.isOn, isFalse);

    // Switching on while locked: PIN prompt; wrong PIN does nothing.
    await tester.tap(switchFor('Borehole Pump'));
    await tester.pumpAndSettle();
    expect(find.text('PIN required to start machines'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '0000');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect PIN'), findsOneWidget);
    expect(deviceService.getDeviceById('5')!.isOn, isFalse);

    await tester.enterText(find.byType(TextField), '2468');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(deviceService.getDeviceById('5')!.isOn, isTrue);
  });

  testWidgets('Cut All only acts after confirmation', (tester) async {
    await openControlTab(tester);
    final running = deviceService.getActiveDevices().length;
    expect(running, greaterThan(0));

    await tester.tap(find.text('Cut All'));
    await tester.pumpAndSettle();
    expect(find.text('Cut power to all machines?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deviceService.getActiveDevices(), hasLength(running));

    await tester.tap(find.text('Cut All'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Cut All'));
    await tester.pumpAndSettle();
    expect(deviceService.getActiveDevices(), isEmpty);
  });
}
