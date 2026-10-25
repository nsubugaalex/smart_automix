import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../services/activity_log.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Icon and colour for an activity entry. Colour is never the only cue:
/// each entry also has its icon and wording.
(IconData, Color?) activityStyle(ActivityKind kind) => switch (kind) {
      ActivityKind.command => (Icons.touch_app_outlined, null),
      ActivityKind.otherPhone => (Icons.phone_android, null),
      ActivityKind.panel => (Icons.developer_board, null),
      ActivityKind.commandFailed => (Icons.sync_problem, UgandaTheme.warning),
      ActivityKind.fault => (Icons.report_problem_outlined, UgandaTheme.danger),
      ActivityKind.supply => (Icons.flash_off, UgandaTheme.danger),
      ActivityKind.generator => (Icons.local_gas_station_outlined, null),
      ActivityKind.link => (Icons.cloud_outlined, null),
    };

enum _Filter { all, machines, problems }

/// The full activity timeline, newest first, grouped by day.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  _Filter _filter = _Filter.all;

  static final _day = DateFormat('EEEE d MMMM');
  static final _time = DateFormat.Hm();

  bool _shows(ActivityEntry e) => switch (_filter) {
        _Filter.all => true,
        _Filter.machines => e.machineId != null,
        _Filter.problems => const {
            ActivityKind.commandFailed,
            ActivityKind.fault,
            ActivityKind.supply,
          }.contains(e.kind),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          IconButton(
            tooltip: 'Copy as CSV',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: activityLog.toCsv()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Activity log copied as CSV')));
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: activityLog,
        builder: (context, _) {
          final entries = activityLog.entries.where(_shows).toList();
          final rows = <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final (f, label) in const [
                    (_Filter.all, 'All'),
                    (_Filter.machines, 'Machines'),
                    (_Filter.problems, 'Problems'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                ],
              ),
            ),
          ];
          if (entries.isEmpty) {
            rows.add(const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Nothing recorded yet.')),
            ));
          }
          String? lastDay;
          for (final e in entries) {
            final day = _day.format(e.time);
            if (day != lastDay) {
              lastDay = day;
              rows.add(Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(day, style: Theme.of(context).textTheme.labelLarge),
              ));
            }
            rows.add(ActivityTile(entry: e, time: _time.format(e.time)));
          }
          return ListView(children: rows);
        },
      ),
    );
  }
}

class ActivityTile extends StatelessWidget {
  const ActivityTile({super.key, required this.entry, required this.time});

  final ActivityEntry entry;
  final String time;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = activityStyle(entry.kind);
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(entry.text),
      trailing: Text(time, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// The latest few entries, for the Dashboard.
class RecentActivityCard extends StatelessWidget {
  const RecentActivityCard({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: activityLog,
      builder: (context, _) {
        final recent = activityLog.entries.take(count).toList();
        if (recent.isEmpty) return const SizedBox.shrink();
        final time = DateFormat('d MMM, HH:mm');
        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                title: Text('Recent activity',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                trailing: TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/activity'),
                  child: const Text('See all'),
                ),
              ),
              for (final e in recent)
                ActivityTile(entry: e, time: time.format(e.time)),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
