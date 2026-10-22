import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_automix/services/energy_log.dart';
import 'package:smart_automix/widgets/common/energy_history_card.dart';

void main() {
  final now = DateTime(2026, 10, 31, 15);

  Future<void> show(WidgetTester tester, EnergyLog log) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: EnergyHistoryCard(history: log, clock: () => now),
        ),
      ),
    ));
  }

  /// [kwh] on each given day of October, read from just after midnight.
  EnergyLog logOf(Map<int, double> kwhByDay) {
    final log = EnergyLog();
    var register = 1000.0;
    kwhByDay.forEach((day, kwh) {
      log.record(
          registerKwh: register,
          at: DateTime(2026, 10, day, 0, 1),
          ratePerKwh: 1000);
      register += kwh;
      log.record(
          registerKwh: register,
          at: DateTime(2026, 10, day, 23, 59),
          ratePerKwh: 1000);
    });
    return log;
  }

  testWidgets('explains itself when there is no meter history', (tester) async {
    await show(tester, EnergyLog());
    expect(find.text('Daily energy history'), findsOneWidget);
    expect(find.textContaining('supply meter'), findsOneWidget);
  });

  testWidgets('shows the latest day, and tapping a bar selects its day',
      (tester) async {
    await show(tester, logOf({1: 40, 30: 12, 31: 20}));
    expect(find.text('Sat 31 Oct'), findsOneWidget);
    expect(find.text('20.0 kWh'), findsWidgets);

    // 30 slots, the last one today: the second-to-last is 30 Oct.
    final chart = find.byKey(EnergyHistoryCard.chartKey);
    final box = tester.getRect(chart);
    const axis = 40.0;
    final slot = (box.width - axis) / 30;
    await tester.tapAt(Offset(box.left + axis + slot * 28.5, box.center.dy));
    await tester.pump();
    expect(find.text('Fri 30 Oct'), findsOneWidget);
    expect(find.text('12.0 kWh'), findsWidgets);

    // A day with no readings says so.
    await tester.tapAt(Offset(box.left + axis + slot * 10.5, box.center.dy));
    await tester.pump();
    expect(find.text('No readings'), findsOneWidget);
  });

  testWidgets('month total includes days before the 30-day window',
      (tester) async {
    // 1 Oct is outside the last 30 days on 31 Oct, but in this month.
    await show(tester, logOf({1: 40, 31: 20}));
    expect(find.textContaining('Last 30 days: 20.0 kWh'), findsOneWidget);
    expect(find.textContaining('This month: 60.0 kWh'), findsOneWidget);
  });

  testWidgets('Copy CSV puts the history on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final log = logOf({31: 20});
    await show(tester, log);
    await tester.tap(find.text('Copy CSV'));
    await tester.pump();
    expect(copied, log.toCsv(now: now));
    expect(find.textContaining('copied as CSV'), findsOneWidget);
  });
}
