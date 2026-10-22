import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smart_automix/main.dart';
import 'package:smart_automix/screens/settings/security_screen.dart';
import 'package:smart_automix/services/device_service.dart';
import 'package:smart_automix/services/security_service.dart';

/// UI-level checks of the control safety rules in control_actions.dart.
void main() {
  Future<void> openControlTab(WidgetTester tester, {String? pin}) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await securityService.init();
    // A PIN loaded from storage (rather than just set) starts locked.
    if (pin != null) await securityService.setPin(pin);
    await securityService.init();
    await deviceService.init();

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

  Future<void> enterPin(WidgetTester tester, String pin) async {
    await tester.enterText(find.byType(TextField), pin);
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
  }

  testWidgets('wrong PINs lock entry, even for the right PIN', (tester) async {
    await openControlTab(tester, pin: '2468');
    await tester.tap(switchFor('Borehole Pump'));
    await tester.pumpAndSettle();

    for (var i = 0; i < SecurityService.maxFailedAttempts; i++) {
      await enterPin(tester, '0000');
    }
    expect(find.textContaining('Too many wrong attempts. Locked for'),
        findsOneWidget);

    await enterPin(tester, '2468');
    expect(find.textContaining('Try again in'), findsOneWidget);
    expect(deviceService.getDeviceById('5')!.isOn, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deviceService.getDeviceById('5')!.isOn, isFalse);
  });

  testWidgets(
      'Start All needs the PIN and confirmation, then starts largest first',
      (tester) async {
    await openControlTab(tester, pin: '2468');
    final stopped = deviceService.devices.where((d) => !d.isOn).toList()
      ..sort((a, b) => b.powerConsumption.compareTo(a.powerConsumption));
    expect(stopped.length, greaterThan(1));

    // Cancelling the PIN prompt starts nothing.
    await tester.tap(find.text('Start All'));
    await tester.pumpAndSettle();
    expect(find.text('PIN required to start machines'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Start all machines?'), findsNothing);

    // PIN, then cancelling the confirmation, still starts nothing.
    await tester.tap(find.text('Start All'));
    await tester.pumpAndSettle();
    await enterPin(tester, '2468');
    expect(find.text('Start all machines?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deviceService.getActiveDevices().map((d) => d.id),
        isNot(contains(stopped.first.id)));

    // Confirmed (PIN now unlocked): the largest load starts first and the
    // rest wait their turn.
    await tester.tap(find.text('Start All'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start All'));
    await tester.pump();
    expect(deviceService.getDeviceById(stopped.first.id)!.isOn, isTrue);
    expect(deviceService.getDeviceById(stopped[1].id)!.isOn, isFalse);
    expect(
        find.text('Starting… ${stopped.length - 1} waiting'), findsOneWidget);

    await tester.pump(DeviceService.startStagger);
    await tester.pump();
    for (final d in stopped) {
      expect(deviceService.getDeviceById(d.id)!.isOn, isTrue, reason: d.name);
    }
    expect(deviceService.pendingStarts, 0);
  });

  testWidgets('Cut All during Start All cancels the machines still waiting',
      (tester) async {
    await openControlTab(tester);
    final stopped = deviceService.devices.where((d) => !d.isOn).toList()
      ..sort((a, b) => b.powerConsumption.compareTo(a.powerConsumption));

    await tester.tap(find.text('Start All'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start All'));
    await tester.pump();
    expect(deviceService.getDeviceById(stopped.first.id)!.isOn, isTrue);

    await tester.tap(find.text('Cut All'));
    await tester.pumpAndSettle();
    expect(find.textContaining('start sequence'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Cut All'));
    await tester.pumpAndSettle();
    expect(deviceService.getActiveDevices(), isEmpty);
    expect(deviceService.pendingStarts, 0);

    await tester.pump(DeviceService.startStagger * stopped.length);
    expect(deviceService.getActiveDevices(), isEmpty,
        reason: 'no machine starts after Cut All');
  });

  group('Security settings', () {
    Future<void> openSecurity(WidgetTester tester, {String? pin}) async {
      FlutterSecureStorage.setMockInitialValues({});
      await securityService.init();
      if (pin != null) await securityService.setPin(pin);
      await securityService.init();
      await tester.pumpWidget(const MaterialApp(home: SecurityScreen()));
    }

    Finder requireSwitch() => find.byType(Switch);

    testWidgets('setting a PIN checks the format and the confirmation',
        (tester) async {
      await openSecurity(tester);
      await tester.tap(requireSwitch());
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);

      await tester.enterText(fields.at(0), '12');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Use 4-6 digits'), findsOneWidget);

      await tester.enterText(fields.at(0), '1357');
      await tester.enterText(fields.at(1), '1358');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('PINs do not match'), findsOneWidget);
      expect(securityService.requirePin, isFalse);

      await tester.enterText(fields.at(1), '1357');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(securityService.requirePin, isTrue);
      expect(find.text('PIN enabled'), findsOneWidget);
    });

    testWidgets('turning the PIN off needs the current PIN', (tester) async {
      await openSecurity(tester, pin: '2468');
      await tester.tap(requireSwitch());
      await tester.pumpAndSettle();
      expect(find.text('Enter current PIN to turn it off'), findsOneWidget);

      await enterPin(tester, '0000');
      expect(find.text('Incorrect PIN'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(securityService.requirePin, isTrue);

      await tester.tap(requireSwitch());
      await tester.pumpAndSettle();
      await enterPin(tester, '2468');
      expect(securityService.requirePin, isFalse);
      expect(find.text('PIN turned off'), findsOneWidget);
    });
  });
}
