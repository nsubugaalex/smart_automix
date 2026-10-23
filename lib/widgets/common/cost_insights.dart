import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../models/energy_prices.dart';
import '../../services/energy_insights.dart';
import '../custom/uganda_theme.dart';

String _kwh(double kwh) => '${kwh.toStringAsFixed(1)} kWh';
String _time(DateTime t) => DateFormat.Hm().format(t);

/// The current time-of-use period, and how the last days' grid energy fell
/// across the periods, with what shifting peak use to off-peak would save.
class TimeOfUseCard extends StatelessWidget {
  const TimeOfUseCard({
    super.key,
    required this.timeOfUse,
    required this.standardRate,
    required this.summary,
    required this.now,
    this.days = 30,
  });

  final TimeOfUse timeOfUse;
  final double standardRate;
  final TouSummary? summary;
  final DateTime now;
  final int days;

  /// Same data hue as the energy history chart.
  static Color barColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF3987E5)
          : const Color(0xFF2A78D6);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final band = timeOfUse.bandAt(now);
    final rate = timeOfUse.rateFor(band, standardRate);
    final until = timeOfUse.nextChange(now);
    final s = summary;
    final ratesEntered = timeOfUse.peakRate > timeOfUse.offPeakRate;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time-of-use',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  band == TouBand.peak
                      ? Icons.trending_up
                      : band == TouBand.offPeak
                          ? Icons.nights_stay_outlined
                          : Icons.schedule,
                  color: band == TouBand.peak ? UgandaTheme.warning : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${band.label} now · ${UgandaTheme.formatUgx(rate)}/kWh '
                    'until ${_time(until)}',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            if (band == TouBand.peak && ratesEntered) ...[
              const SizedBox(height: 4),
              Text(
                'Off-peak (${UgandaTheme.formatUgx(timeOfUse.offPeakRate)}/kWh) '
                'starts at '
                '${_time(timeOfUse.nextStartOf(TouBand.offPeak, now))}.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const Divider(height: 24),
            if (s == null)
              Text(
                'The split by period needs hourly figures, which come from '
                'the panel\'s daily totals or the app\'s own meter readings.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text('Grid energy, last $days days',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              for (final b in [TouBand.peak, TouBand.shoulder, TouBand.offPeak])
                _BandRow(
                  label: b.label,
                  kwh: s.kwh[b]!,
                  share: s.shareOf(b),
                  rate: timeOfUse.rateFor(b, standardRate),
                ),
              const SizedBox(height: 8),
              Text(
                !ratesEntered
                    ? 'Enter the peak and off-peak rates from your bill in '
                        'the Tariff tab to see what shifting work would save.'
                    : s.potentialSavingUgx < 1
                        ? 'No peak-period use: nothing to shift.'
                        : 'Running the peak-period work off-peak instead would '
                            'have saved about '
                            '${UgandaTheme.formatUgx(s.potentialSavingUgx)}.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BandRow extends StatelessWidget {
  const _BandRow({
    required this.label,
    required this.kwh,
    required this.share,
    required this.rate,
  });

  final String label;
  final double kwh;
  final double share;
  final double rate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('$label · ${UgandaTheme.formatUgx(rate)}/kWh',
                    style: theme.textTheme.bodyMedium),
              ),
              Text('${_kwh(kwh)} · ${(share * 100).round()}%',
                  style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: share,
              minHeight: 6,
              color: TimeOfUseCard.barColor(context),
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// Standby generator use and what its energy costs against the grid.
class GeneratorCard extends StatelessWidget {
  const GeneratorCard({
    super.key,
    required this.summary,
    required this.onGenerator,
    required this.generatorCostPerKwh,
    required this.gridRateNow,
    this.days = 30,
  });

  final GeneratorSummary? summary;

  /// Null when the panel doesn't report its supply source.
  final bool? onGenerator;
  final double generatorCostPerKwh;
  final double gridRateNow;
  final int days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = summary;
    final gridPerKwh = s?.gridCostPerKwh ?? gridRateNow;
    final times = gridPerKwh > 0 ? generatorCostPerKwh / gridPerKwh : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Standby generator',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                if (onGenerator != null)
                  Chip(
                    avatar: Icon(
                      onGenerator! ? Icons.local_gas_station : Icons.power,
                      size: 18,
                    ),
                    label: Text(onGenerator! ? 'Running now' : 'On grid'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Generator: ${UgandaTheme.formatUgx(generatorCostPerKwh)} per kWh\n'
              'Grid: ${UgandaTheme.formatUgx(gridPerKwh)} per kWh'
              '${times != null && times >= 1.05 ? ' (generator is ${times.toStringAsFixed(1)}×)' : ''}',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            if (s == null)
              Text('The generator hasn\'t run in the last $days days.',
                  style: theme.textTheme.bodySmall)
            else
              Text(
                'Last $days days: ${_kwh(s.generatorKwh)} over '
                '${s.generatorHours.toStringAsFixed(1)} h on '
                '${s.daysUsed} day${s.daysUsed == 1 ? '' : 's'}, '
                'about ${UgandaTheme.formatUgx(s.generatorCostUgx)} in fuel.',
                style: theme.textTheme.bodyMedium,
              ),
            const SizedBox(height: 4),
            Text(
              'Fuel cost uses the price and consumption in the Tariff tab.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
