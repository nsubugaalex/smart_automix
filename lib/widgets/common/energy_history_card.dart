import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../services/energy_log.dart';
import '../custom/uganda_theme.dart';

/// Metered energy per day for the last [days] days: a column chart with a
/// tap/hover readout, totals, a table view and CSV copy.
class EnergyHistoryCard extends StatefulWidget {
  const EnergyHistoryCard({
    super.key,
    required this.history,
    this.days = 30,
    this.clock = DateTime.now,
  });

  /// The chart's plot area, for tests.
  static const chartKey = Key('energy-history-chart');

  final EnergyLog history;
  final int days;
  final DateTime Function() clock;

  @override
  State<EnergyHistoryCard> createState() => _EnergyHistoryCardState();
}

class _EnergyHistoryCardState extends State<EnergyHistoryCard> {
  int? _selected;

  static final _dayFormat = DateFormat('EEE d MMM');

  static String _kwh(double kwh) => '${kwh.toStringAsFixed(1)} kWh';
  static String _time(DateTime t) => DateFormat.Hm().format(t);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = widget.clock();
    final slots = widget.history.lastDays(widget.days, now);
    final recorded = slots.nonNulls.toList();

    if (recorded.isEmpty) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.bar_chart),
          title: const Text('Daily energy history'),
          subtitle: const Text(
            'Appears once the panel reports a supply meter reading. '
            'Without one, the figures above are estimates.',
          ),
        ),
      );
    }

    final selected = _selected ?? slots.lastIndexWhere((d) => d != null);
    final totalKwh = recorded.fold(0.0, (sum, d) => sum + d.kwh);
    final totalCost = recorded.fold(0.0, (sum, d) => sum + d.costUgx);
    final monthKey = EnergyLog.dateKey(now).substring(0, 7);
    // From the whole history: on the 31st the 1st is outside the chart.
    final month = widget.history.days.where((d) => d.date.startsWith(monthKey));
    final monthKwh = month.fold(0.0, (sum, d) => sum + d.kwh);
    final monthCost = month.fold(0.0, (sum, d) => sum + d.costUgx);
    final anyPartial = recorded.any((d) => !d.isCompleteAt(now));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Metered energy per day (kWh)',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Last ${widget.days} days: ${_kwh(totalKwh)} · ${UgandaTheme.formatUgx(totalCost)}\n'
              'This month: ${_kwh(monthKwh)} · '
              '${UgandaTheme.formatUgx(monthCost)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _Readout(
              day: slots[selected],
              date: _slotDate(now, selected),
              now: now,
            ),
            const SizedBox(height: 8),
            Semantics(
              label: 'Daily metered energy chart. '
                  'Total ${_kwh(totalKwh)} over ${recorded.length} days with '
                  'readings. Daily figures are in the table below.',
              child: _Chart(
                slots: slots,
                selected: selected,
                now: now,
                onSelect: (i) => setState(() => _selected = i),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(_dayFormat.format(_slotDate(now, 0)),
                    style: theme.textTheme.labelSmall),
                const Spacer(),
                Text('Today', style: theme.textTheme.labelSmall),
              ],
            ),
            if (anyPartial) ...[
              const SizedBox(height: 8),
              Text(
                'Outlined bars are days without meter readings for the '
                'whole day, so they may be missing some energy.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _copyCsv(context, now),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy CSV'),
              ),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Daily figures'),
              children: [
                for (final d in recorded.reversed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_dayFormat.format(DateTime.parse(d.date))),
                    subtitle: d.isCompleteAt(now)
                        ? null
                        : Text('Read ${_time(d.firstAt)}–${_time(d.lastAt)}'),
                    trailing: Text(
                      '${_kwh(d.kwh)}\n${UgandaTheme.formatUgx(d.costUgx)}',
                      textAlign: TextAlign.end,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  DateTime _slotDate(DateTime now, int index) =>
      DateTime(now.year, now.month, now.day - (widget.days - 1 - index));

  Future<void> _copyCsv(BuildContext context, DateTime now) async {
    await Clipboard.setData(
        ClipboardData(text: widget.history.toCsv(now: now)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Energy history copied as CSV, '
            'ready to paste into a spreadsheet')));
  }
}

/// The selected day's figures, above the chart.
class _Readout extends StatelessWidget {
  const _Readout({required this.day, required this.date, required this.now});

  final DailyEnergy? day;
  final DateTime date;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = day;
    final label = _EnergyHistoryCardState._dayFormat.format(date);
    // Wraps rather than overflowing on narrow screens or with large text.
    return Wrap(
      spacing: 10,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        if (d == null)
          Text('No readings', style: theme.textTheme.bodyMedium)
        else ...[
          Text(_EnergyHistoryCardState._kwh(d.kwh),
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          Text(UgandaTheme.formatUgx(d.costUgx),
              style: theme.textTheme.bodyMedium),
          if (!d.isCompleteAt(now))
            Text(
              'read ${_EnergyHistoryCardState._time(d.firstAt)}–'
              '${_EnergyHistoryCardState._time(d.lastAt)}',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ],
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({
    required this.slots,
    required this.selected,
    required this.now,
    required this.onSelect,
  });

  final List<DailyEnergy?> slots;
  final int selected;
  final DateTime now;
  final ValueChanged<int> onSelect;

  /// Single data hue (not the green "running" status colour), validated
  /// for contrast on the light and dark card surfaces.
  static const _lightBar = Color(0xFF2A78D6);
  static const _darkBar = Color(0xFF3987E5);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      void select(Offset p) {
        final plotLeft = _ChartPainter.axisWidth;
        final slotWidth = (width - plotLeft) / slots.length;
        final i = ((p.dx - plotLeft) / slotWidth).floor();
        if (i >= 0 && i < slots.length && i != selected) onSelect(i);
      }

      return MouseRegion(
        onHover: (e) => select(e.localPosition),
        child: GestureDetector(
          onTapDown: (e) => select(e.localPosition),
          onHorizontalDragUpdate: (e) => select(e.localPosition),
          child: CustomPaint(
            key: EnergyHistoryCard.chartKey,
            size: Size(width, 160),
            painter: _ChartPainter(
              slots: slots,
              selected: selected,
              now: now,
              bar: dark ? _darkBar : _lightBar,
              grid: theme.colorScheme.outlineVariant,
              ink: theme.colorScheme.onSurfaceVariant,
              selectedRing: theme.colorScheme.onSurface,
              labelStyle: theme.textTheme.labelSmall!,
            ),
          ),
        ),
      );
    });
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.slots,
    required this.selected,
    required this.now,
    required this.bar,
    required this.grid,
    required this.ink,
    required this.selectedRing,
    required this.labelStyle,
  });

  static const axisWidth = 40.0;
  static const _gap = 2.0;
  static const _radius = Radius.circular(4);

  final List<DailyEnergy?> slots;
  final int selected;
  final DateTime now;
  final Color bar;
  final Color grid;
  final Color ink;
  final Color selectedRing;
  final TextStyle labelStyle;

  /// A round gridline step (1, 2, 2.5 or 5 × 10ⁿ) so that [lines] steps
  /// just reach [max].
  static double _niceStep(double max, int lines) {
    if (max <= 0) return 1;
    final raw = max / lines;
    final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor());
    for (final m in [1, 2, 2.5, 5, 10]) {
      if (m * magnitude >= raw) return (m * magnitude).toDouble();
    }
    return (10 * magnitude).toDouble();
  }

  static String _axisLabel(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  @override
  void paint(Canvas canvas, Size size) {
    const lines = 4;
    const top = 8.0;
    final bottom = size.height;
    final maxKwh = slots.fold(0.0, (m, d) => math.max(m, d?.kwh ?? 0));
    final step = _niceStep(maxKwh, lines);
    final axisMax = step * lines;
    double y(double kwh) => bottom - (bottom - top) * (kwh / axisMax);

    // Recessive gridlines with labels; the baseline slightly stronger.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= lines; i++) {
      final value = step * i;
      final gy = y(value);
      canvas.drawLine(Offset(axisWidth, gy), Offset(size.width, gy),
          gridPaint..strokeWidth = i == 0 ? 1.5 : 1);
      final label = TextPainter(
        text: TextSpan(
            text: _axisLabel(value), style: labelStyle.copyWith(color: ink)),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
          canvas, Offset(axisWidth - 6 - label.width, gy - label.height / 2));
    }

    final slotWidth = (size.width - axisWidth) / slots.length;
    final fill = Paint()..color = bar;
    final partialFill = Paint()..color = bar.withValues(alpha: 0.35);
    final outline = Paint()
      ..color = bar
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final ring = Paint()
      ..color = selectedRing
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (var i = 0; i < slots.length; i++) {
      final d = slots[i];
      final left = axisWidth + i * slotWidth + _gap / 2;
      final right = left + slotWidth - _gap;
      if (d == null || right <= left) continue;
      // At least a sliver, so a day with readings but ~0 kWh still shows.
      final barTop = math.min(y(d.kwh), bottom - 2);
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTRB(left, barTop, right, bottom),
        topLeft: _radius,
        topRight: _radius,
      );
      if (d.isCompleteAt(now)) {
        canvas.drawRRect(rect, fill);
      } else {
        canvas.drawRRect(rect, partialFill);
        canvas.drawRRect(rect.deflate(0.75), outline);
      }
      if (i == selected) canvas.drawRRect(rect.inflate(1.5), ring);
    }

    // Selected day with no record: a light marker so the readout has a
    // visible anchor.
    if (slots[selected] == null) {
      final cx = axisWidth + (selected + 0.5) * slotWidth;
      canvas.drawLine(Offset(cx, top), Offset(cx, bottom), gridPaint);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.slots != slots ||
      old.selected != selected ||
      old.bar != bar ||
      old.grid != grid ||
      old.now.day != now.day;
}
