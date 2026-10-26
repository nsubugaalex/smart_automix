import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/machine_health.dart';
import '../../services/machine_health_service.dart';
import '../custom/uganda_theme.dart';

String _amps(double a) => '${a.toStringAsFixed(a < 100 ? 1 : 0)} A';

/// A machine's running-current health: what's normal, what's changed, and
/// its daily average current with the usual range shaded.
class MachineHealthView extends StatelessWidget {
  const MachineHealthView(
      {super.key, required this.machineId, required this.type, this.service});

  final String machineId;
  final String type;

  /// Defaults to the app-wide service.
  final MachineHealthService? service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final health = service ?? machineHealthService;
    final s = health.statusOf(machineId);
    final days = health.daysOf(machineId);

    if (s.isLearning) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const Icon(Icons.insights_outlined, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Learning its normal current: ${s.learnedDays} of '
                '${MachineHealthAnalysis.daysToLearn} days of running',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    final finding = s.finding;
    final low = s.usualLow!.clamp(0, double.infinity).toDouble();
    final usual = 'usually ${_amps(low).replaceAll(' A', '')}–'
        '${_amps(s.usualHigh!)}';
    final (IconData icon, Color color, String text) = switch (finding) {
      null => (
          Icons.check_circle_outline,
          UgandaTheme.running,
          s.recent == null
              ? 'Normal running current learned: $usual'
              : 'Running current normal: ${_amps(s.recent!)} ($usual)',
        ),
      HealthKind.high => (
          Icons.trending_up,
          UgandaTheme.warning,
          'Drawing ${s.percent!.round()}% more current than usual for '
              '${s.days} days of running: ${_amps(s.recent!)} ($usual). '
              'Check for ${MachineHealthAnalysis.causes(finding, type)}.',
        ),
      HealthKind.low => (
          Icons.trending_down,
          UgandaTheme.warning,
          'Drawing ${(-s.percent!).round()}% less current than usual for '
              '${s.days} days of running: ${_amps(s.recent!)} ($usual). '
              'Check for ${MachineHealthAnalysis.causes(finding, type)}.',
        ),
      HealthKind.erratic => (
          Icons.ssid_chart,
          UgandaTheme.warning,
          'Current much more uneven than usual for ${s.days} days of '
              'running. Check for ${MachineHealthAnalysis.causes(finding, type)}.',
        ),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(text,
                    style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: finding == null ? null : FontWeight.bold)),
              ),
            ],
          ),
          if (days.length >= 2) ...[
            const SizedBox(height: 6),
            Semantics(
              label:
                  'Daily average running current, last ${math.min(days.length, 30)} '
                  'days, against the usual range',
              child: CustomPaint(
                size: const Size(double.infinity, 56),
                painter: _CurrentChart(
                  days:
                      days.length > 30 ? days.sublist(days.length - 30) : days,
                  low: s.usualLow!,
                  high: s.usualHigh!,
                  line: theme.brightness == Brightness.dark
                      ? const Color(0xFF3987E5)
                      : const Color(0xFF2A78D6),
                  ink: theme.colorScheme.onSurfaceVariant,
                  label: theme.textTheme.labelSmall!,
                ),
              ),
            ),
            Text(
                'Daily average while running, last '
                '${days.length > 30 ? 30 : days.length} days; shaded: usual range',
                style: theme.textTheme.labelSmall),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () async {
                await health.relearn(machineId);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Learning its normal current again from '
                        'today, e.g. after a repair')));
              },
              child: const Text('Relearn normal'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Daily average current as a line, with the usual range as a band.
class _CurrentChart extends CustomPainter {
  _CurrentChart({
    required this.days,
    required this.low,
    required this.high,
    required this.line,
    required this.ink,
    required this.label,
  });

  final List<DayCurrent> days;
  final double low;
  final double high;
  final Color line;
  final Color ink;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 36.0;
    final means = [for (final d in days) d.mean];
    final lo = math.min(means.reduce(math.min), low) * 0.95;
    final hi = math.max(means.reduce(math.max), high) * 1.05;
    double y(double v) => size.height - (v - lo) / (hi - lo) * size.height;
    double x(int i) =>
        left +
        (size.width - left) * (days.length == 1 ? 0.5 : i / (days.length - 1));

    // Usual range.
    canvas.drawRect(
      Rect.fromLTRB(left, y(high), size.width, y(low)),
      Paint()..color = line.withValues(alpha: 0.14),
    );
    for (final v in [high, low]) {
      final tp = TextPainter(
        text: TextSpan(text: _amps(v), style: label.copyWith(color: ink)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left - 4 - tp.width, y(v) - tp.height / 2));
    }

    final path = Path()..moveTo(x(0), y(means[0]));
    for (var i = 1; i < means.length; i++) {
      path.lineTo(x(i), y(means[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    // The latest day, marked.
    canvas.drawCircle(
        Offset(x(means.length - 1), y(means.last)), 4, Paint()..color = line);
  }

  @override
  bool shouldRepaint(_CurrentChart old) =>
      old.days != days ||
      old.low != low ||
      old.high != high ||
      old.line != line;
}
