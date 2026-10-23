import 'package:flutter/material.dart';
import '../../constants/uedcl_tariffs.dart';
import '../../models/device_model.dart';
import '../../models/machine_load.dart';
import '../../services/device_service.dart';
import '../../services/tariff_service.dart';
import '../../services/energy_insights.dart';
import '../../widgets/common/consumption_gauge.dart';
import '../../widgets/common/cost_insights.dart';
import '../../widgets/common/energy_history_card.dart';
import '../../widgets/common/responsive_page.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Live view of total electrical load and the UEDCL-tariff-based cost
/// estimate for the facility, broken down per machine, with overload
/// warnings against each machine's breaker rating. Uses the panel's power
/// readings where it has them and nameplate estimates otherwise, and says
/// which.
/// Body-only (no Scaffold/AppBar) — hosted inside [MainShell].
class EnergyMonitorBody extends StatelessWidget {
  const EnergyMonitorBody({super.key});

  /// Assumed main-supply capacity used for the gauge threshold. This should
  /// match the facility's actual UEDCL supply/breaker rating.
  static const double assumedSupplyCapacityWatts = 15000;

  /// Time-of-use and generator cards, each only when it applies.
  static List<Widget> _costInsights() {
    final now = DateTime.now();
    final recent =
        deviceService.energyHistory.lastDays(30, now).nonNulls.toList();
    final tou = tariffService.timeOfUse;
    final generator = GeneratorSummary.of(recent);
    final onGenerator = deviceService.onGenerator;
    return [
      if (tou.enabled) ...[
        const SizedBox(height: 12),
        TimeOfUseCard(
          timeOfUse: tou,
          standardRate: tariffService.ratePerKwh,
          summary: TouSummary.of(recent, tou),
          now: now,
        ),
      ],
      if (generator != null || onGenerator != null) ...[
        const SizedBox(height: 12),
        GeneratorCard(
          summary: generator,
          onGenerator: onGenerator,
          generatorCostPerKwh: tariffService.generatorRatePerKwh,
          gridRateNow: tariffService.gridRateAt(now),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([deviceService, tariffService]),
      builder: (context, _) {
        final devices = deviceService.devices;
        final totalWatts = deviceService.totalPowerConsumption;
        final totalKva = deviceService.totalApparentPowerKva;
        final dailyKwh = deviceService.totalDailyEnergyKWh;
        final dailyCost = deviceService.totalEstimatedDailyCostUgx;
        final monthlyCost = deviceService.totalEstimatedMonthlyCostUgx;
        final overloaded = deviceService.getOverloadedDevices();
        final source = deviceService.loadSource;
        final meteredKwh = deviceService.meteredEnergyTodayKwh;
        final meteredCost = deviceService.meteredCostTodayUgx;
        final meteredSince = deviceService.meteredEnergyTodaySince;

        // A single lazily-built scroll view: the header/stats are one
        // sliver, and the (potentially long) per-machine list is a
        // SliverList so only visible rows are built as the panel grows.
        return ResponsivePage(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: RepaintBoundary(
                          child: ConsumptionGauge(
                            currentWatts: totalWatts,
                            maxWatts: assumedSupplyCapacityWatts,
                            size: 200,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(child: _LoadSourceChip(source: source)),
                      const SizedBox(height: 16),
                      if (meteredKwh != null && meteredCost != null) ...[
                        Row(
                          children: [
                            Expanded(
                              child: _StatTile(
                                label: _meteredLabel('Metered Today',
                                    since: meteredSince),
                                value: '${meteredKwh.toStringAsFixed(1)} kWh',
                                icon: Icons.speed,
                                color: UgandaTheme.running,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _StatTile(
                                label: _meteredLabel('Cost Today',
                                    since: meteredSince),
                                value: UgandaTheme.formatUgx(meteredCost),
                                icon: Icons.payments,
                                color: UgandaTheme.red,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: _StatTile(
                              label: 'Est. Daily Energy',
                              value: '${dailyKwh.toStringAsFixed(1)} kWh',
                              icon: Icons.energy_savings_leaf,
                              color: UgandaTheme.running,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _StatTile(
                              label: 'Running Load',
                              value: '${totalKva.toStringAsFixed(1)} kVA',
                              icon: Icons.bolt,
                              color: UgandaTheme.warning,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _StatTile(
                              label: 'Est. Daily Cost',
                              value: UgandaTheme.formatUgx(dailyCost),
                              icon: Icons.receipt_long,
                              color: UgandaTheme.red,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _StatTile(
                              label: 'Est. Monthly Bill',
                              value: UgandaTheme.formatUgx(monthlyCost),
                              icon: Icons.calendar_month,
                              color: UgandaTheme.red,
                            ),
                          ),
                        ],
                      ),
                      if (overloaded.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Card(
                          color: UgandaTheme.tintedCard(
                              context, UgandaTheme.danger,
                              alpha: 25),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.warning_amber,
                                    color: UgandaTheme.danger),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    '${overloaded.length} machine(s) exceed their breaker '
                                    'rating: ${overloaded.map((d) => d.name).join(', ')}.',
                                    style: const TextStyle(
                                      color: UgandaTheme.danger,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const Icon(Icons.info_outline,
                                  size: 20, color: Colors.grey),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Billed as ${tariffService.category.label} at '
                                  '${UgandaTheme.formatUgx(tariffService.ratePerKwh)}/kWh. '
                                  'Daily and monthly estimates assume each machine runs '
                                  'its configured hours per day; the monthly bill adds '
                                  'your fixed charge over '
                                  '${TariffService.daysPerMonth} days. Update the rate in '
                                  'the Tariff tab to match your current UEDCL bill.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      EnergyHistoryCard(history: deviceService.energyHistory),
                      ..._costInsights(),
                      const SizedBox(height: 24),
                      Text(
                        'Load per machine',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 12),
                      if (devices.isEmpty) const Text('No machines added yet'),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, index) => Padding(
                    key: ValueKey(devices[index].id),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _MachineLoadTile(
                      device: devices[index],
                      load: deviceService.loadOf(devices[index]),
                    ),
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
            ],
          ),
        );
      },
    );
  }
}

class _MachineLoadTile extends StatelessWidget {
  const _MachineLoadTile({required this.device, required this.load});

  final DeviceModel device;
  final MachineLoad load;

  @override
  Widget build(BuildContext context) {
    final overloaded = load.exceedsBreaker;
    final showAmps = load.isMeasured || device.isOn;
    return Card(
      color: overloaded
          ? UgandaTheme.tintedCard(context, UgandaTheme.danger, alpha: 20)
          : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: device.isOn ? UgandaTheme.running : UgandaTheme.off,
          child: Icon(device.icon, color: Colors.white),
        ),
        title: Row(
          children: [
            Flexible(child: Text(device.name)),
            if (overloaded) ...[
              const SizedBox(width: 6),
              const Icon(Icons.warning_amber,
                  color: UgandaTheme.danger, size: 18),
            ],
          ],
        ),
        subtitle: Text(
          showAmps
              ? '${device.location} • ${load.amps.toStringAsFixed(1)} A '
                  '${load.isMeasured ? 'live' : 'est.'}'
              : device.location,
          style: overloaded ? const TextStyle(color: UgandaTheme.danger) : null,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(load.isMeasured
                ? '${load.watts.toStringAsFixed(0)} W'
                : '${device.powerConsumption.toStringAsFixed(0)} W rated'),
            Text(
              UgandaTheme.formatUgx(
                  tariffService.costFor(device.dailyEnergyKWh())),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Metered Today", or "Metered since 14:05" when the app only started
/// seeing the meter partway through the day.
String _meteredLabel(String label, {DateTime? since}) {
  if (since == null || (since.hour == 0 && since.minute < 5)) return label;
  final time = '${since.hour.toString().padLeft(2, '0')}:'
      '${since.minute.toString().padLeft(2, '0')}';
  return '${label.replaceFirst(' Today', '')} since $time';
}

class _LoadSourceChip extends StatelessWidget {
  const _LoadSourceChip({required this.source});

  final LoadSource source;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (source) {
      LoadSource.measured => (
          Icons.sensors,
          'Measured by the panel',
          UgandaTheme.running
        ),
      LoadSource.partlyMeasured => (
          Icons.sensors,
          'Partly measured, partly estimated',
          UgandaTheme.warning
        ),
      LoadSource.estimated => (
          Icons.calculate_outlined,
          'Estimated from machine ratings',
          Colors.grey
        ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
