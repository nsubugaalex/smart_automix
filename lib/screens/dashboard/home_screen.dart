import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/device_service.dart';
import '../../widgets/common/device_card.dart';
import '../../widgets/common/responsive_page.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Facility dashboard: quick stats, running machines, and the full
/// machine list. Body-only (no Scaffold/AppBar/Drawer) — hosted inside
/// [MainShell], which owns the chrome shared across tabs.
class DashboardBody extends StatefulWidget {
  const DashboardBody({super.key});

  @override
  State<DashboardBody> createState() => _DashboardBodyState();
}

class _DashboardBodyState extends State<DashboardBody> {
  @override
  void initState() {
    super.initState();
    deviceService.init();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceService>(
      builder: (context, deviceService, child) {
        if (deviceService.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        return _buildBody(context, deviceService);
      },
    );
  }

  // Main body content — a single lazily-built scroll view: the header,
  // stats and "Running Machines" preview are one sliver, and the
  // "All Machines" list (which can grow unbounded as machines are added)
  // is a SliverList so only the rows currently on screen are built.
  Widget _buildBody(BuildContext context, DeviceService deviceService) {
    final allDevices = deviceService.devices;

    return RefreshIndicator(
      onRefresh: () => deviceService.refresh(),
      child: ResponsivePage(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16.0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildWelcomeSection(context, deviceService),
                    const SizedBox(height: 24),
                    _buildQuickStats(context, deviceService),
                    const SizedBox(height: 24),
                    _buildActiveDevicesSection(context, deviceService),
                    const SizedBox(height: 24),
                    Text(
                      'All Machines',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 12),
                    if (allDevices.isEmpty) const Text('No machines added yet'),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              sliver: SliverList.builder(
                itemCount: allDevices.length,
                itemBuilder: (context, index) {
                  final device = allDevices[index];
                  return Padding(
                    key: ValueKey(device.id),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DeviceCard(
                      device: device,
                      onToggle: (_) => deviceService.toggleDevice(device.id),
                    ),
                  );
                },
              ),
            ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomeSection(BuildContext context, DeviceService deviceService) {
    final activeCount = deviceService.getActiveDevices().length;
    final totalCount = deviceService.devices.length;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            const CircleAvatar(
              backgroundColor: UgandaTheme.black,
              child: Icon(Icons.electrical_services, color: UgandaTheme.yellow),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Facility Overview',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  Text(
                    '$activeCount of $totalCount machines running',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickStats(BuildContext context, DeviceService deviceService) {
    final overloadedCount = deviceService.getOverloadedDevices().length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Stats',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                context,
                icon: Icons.flash_on,
                color: UgandaTheme.warning,
                value: '${deviceService.totalPowerConsumption.toStringAsFixed(0)}W',
                label: 'Power Usage',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                context,
                icon: Icons.bolt,
                color: UgandaTheme.warning,
                value: '${deviceService.totalCurrentDrawAmps.toStringAsFixed(1)}A',
                label: 'Current Draw',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                context,
                icon: Icons.receipt_long,
                color: UgandaTheme.red,
                value: UgandaTheme.formatUgx(deviceService.totalEstimatedDailyCostUgx),
                label: 'Est. Daily Cost',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                context,
                icon: overloadedCount > 0 ? Icons.warning_amber : Icons.check_circle,
                color: overloadedCount > 0 ? UgandaTheme.danger : UgandaTheme.running,
                value: '$overloadedCount',
                label: 'Overloaded',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String value,
    required String label,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveDevicesSection(BuildContext context, DeviceService deviceService) {
    final activeDevices = deviceService.getActiveDevices();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Running Machines',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            if (activeDevices.isNotEmpty)
              TextButton.icon(
                onPressed: () => deviceService.turnOffAllDevices(),
                icon: const Icon(Icons.power_off, size: 16),
                label: const Text('Cut All'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (activeDevices.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.power_off, size: 48, color: Colors.grey),
                    SizedBox(height: 8),
                    Text(
                      'No machines running',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Column(
            children: activeDevices
                .map(
                  (device) => Padding(
                    key: ValueKey('active-${device.id}'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DeviceCard(
                      device: device,
                      onToggle: (_) => deviceService.toggleDevice(device.id),
                    ),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}
