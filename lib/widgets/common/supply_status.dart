import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../models/supply.dart';
import '../../services/device_service.dart';
import '../custom/uganda_theme.dart';

/// "L1 231 V · L2 183 V · L3 no reading", with non-breaking spaces so a
/// line never breaks inside one phase's reading.
String formatPhaseVolts(List<double?> volts) => [
      for (var i = 0; i < volts.length; i++)
        'L${i + 1} ${volts[i] == null ? 'no reading' : '${volts[i]!.round()} V'}'
    ].join(' · ');

/// Shown while the panel reports a supply fault or is waiting for the
/// supply to settle: explains why machines are off and won't start.
class SupplyBanner extends StatelessWidget {
  const SupplyBanner({super.key, this.padding = EdgeInsets.zero});

  /// Space around the banner, only taken up while it is shown.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: deviceService,
      builder: (context, _) {
        final state = deviceService.supplyState;
        if (state == null || state == SupplyState.ok) {
          return const SizedBox.shrink();
        }
        final fault = state.isFault;
        final color = fault ? UgandaTheme.danger : UgandaTheme.warning;
        final volts = deviceService.supplyVolts;
        return Padding(
          padding: padding,
          child: Card(
            color: UgandaTheme.tintedCard(context, color),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(fault ? Icons.flash_off : Icons.hourglass_top,
                      color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(state.label,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        Text(
                          fault
                              ? 'The panel switched all machines off to '
                                  'protect them. Starts are refused until the '
                                  'supply is back and steady.'
                              : 'The supply is back in range. Starts are '
                                  'allowed once it has stayed steady; '
                                  'machines are not restarted automatically.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (volts != null && volts.isNotEmpty)
                          Text(formatPhaseVolts(volts),
                              style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Supply quality on the Energy tab: the state now, phase voltages, power
/// cuts and faults over the last [days] days, and the recent log.
class SupplyCard extends StatelessWidget {
  const SupplyCard({
    super.key,
    required this.state,
    required this.volts,
    required this.events,
    required this.now,
    this.days = 30,
    this.shown = 8,
  });

  final SupplyState state;
  final List<double?>? volts;

  /// Newest first.
  final List<SupplyEvent> events;
  final DateTime now;
  final int days;
  final int shown;

  static final _when = DateFormat('EEE d MMM, HH:mm');

  static String csv(List<SupplyEvent> events) {
    String time(DateTime? t) =>
        t == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(t);
    final rows = [
      'kind,phase,from,to,minutes,min_volts,max_volts',
      for (final e in events.reversed)
        [
          e.kind.wireName,
          e.phase,
          time(e.from),
          time(e.to),
          e.duration?.inMinutes ?? '',
          e.minVolts.toStringAsFixed(0),
          e.maxVolts.toStringAsFixed(0),
        ].join(','),
    ];
    return '${rows.join('\n')}\n';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final since = now.subtract(Duration(days: days));
    final recent =
        events.where((e) => e.from == null || e.from!.isAfter(since)).toList();
    final cuts = recent.where((e) => e.kind == SupplyState.outage).toList();
    final cutTime =
        cuts.fold(Duration.zero, (t, e) => t + (e.duration ?? Duration.zero));
    final faults = recent.length - cuts.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Supply quality',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  state.isFault
                      ? Icons.flash_off
                      : state == SupplyState.settling
                          ? Icons.hourglass_top
                          : Icons.check_circle_outline,
                  color: state.isFault
                      ? UgandaTheme.danger
                      : state == SupplyState.settling
                          ? UgandaTheme.warning
                          : UgandaTheme.running,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.label, style: theme.textTheme.bodyLarge),
                      if (volts != null && volts!.isNotEmpty)
                        Text(formatPhaseVolts(volts!),
                            style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Last $days days: ${cuts.length} power cut'
              '${cuts.length == 1 ? '' : 's'}'
              '${cuts.isEmpty ? '' : ' (${formatDuration(cutTime)} without power)'}'
              ', $faults voltage or phase fault${faults == 1 ? '' : 's'}.',
              style: theme.textTheme.bodyMedium,
            ),
            if (events.isNotEmpty) ...[
              const Divider(height: 24),
              for (final e in events.take(shown))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.summary, style: theme.textTheme.bodyMedium),
                      Text(
                        [
                          if (e.from != null) _when.format(e.from!),
                          if (e.isOngoing)
                            'still going on'
                          else if (e.duration != null)
                            formatDuration(e.duration!),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: csv(events)));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Supply log copied as CSV, e.g. for '
                            'a complaint to UEDCL')));
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy log as CSV'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
