import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../models/maintenance.dart';
import '../../services/device_service.dart';
import '../../services/machine_health_service.dart';
import '../../services/maintenance_service.dart';
import '../../widgets/common/machine_health_view.dart';
import '../../widgets/custom/uganda_theme.dart';

final _hours = NumberFormat('#,##0');
String formatHours(double h) => '${_hours.format(h.floor())} h';

/// Running hours and maintenance tasks for every machine, and the standby
/// generator.
class MaintenanceScreen extends StatelessWidget {
  const MaintenanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Maintenance')),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [maintenanceService, deviceService, machineHealthService]),
        builder: (context, _) {
          final machines = [
            for (final d in deviceService.devices)
              (id: d.id, name: d.name, type: d.type),
            if (maintenanceService.hasGenerator)
              (
                id: MaintenanceTask.generatorId,
                name: 'Standby generator',
                type: MaintenanceTask.generatorId,
              ),
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Running hours are counted by the panel (or by this app '
                'while it can see a machine running). Suggested tasks are '
                'only starting points: check each machine\'s manual.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (machines.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No machines added yet')),
                ),
              for (final m in machines)
                _MachineCard(id: m.id, name: m.name, type: m.type),
            ],
          );
        },
      ),
    );
  }
}

class _MachineCard extends StatelessWidget {
  const _MachineCard(
      {required this.id, required this.name, required this.type});

  final String id;
  final String name;
  final String type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hours = maintenanceService.hoursOf(id);
    final tasks = maintenanceService.tasksFor(id)
      ..sort((a, b) => maintenanceService
          .statusOf(b)
          .index
          .compareTo(maintenanceService.statusOf(a).index));
    final source = id == MaintenanceTask.generatorId
        ? 'from the generator run time'
        : maintenanceService.countedByPanel(id)
            ? 'counted by the panel'
            : 'counted by this app';
    final suggestions = MaintenanceTask.suggestionsFor(type);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Text(formatHours(hours), style: theme.textTheme.titleMedium),
              ],
            ),
            Text('Running hours, $source', style: theme.textTheme.bodySmall),
            if (id != MaintenanceTask.generatorId)
              MachineHealthView(machineId: id, type: type),
            for (final t in tasks) _TaskRow(task: t, hours: hours),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => showTaskDialog(context, machineId: id),
                  icon: const Icon(Icons.add),
                  label: const Text('Add task'),
                ),
                if (tasks.isEmpty && suggestions.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => maintenanceService.addSuggested(id, type),
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text('Add ${suggestions.length} suggested'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.hours});

  final MaintenanceTask task;
  final double hours;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final status = maintenanceService.statusOf(task);
    final color = switch (status) {
      TaskStatus.due => UgandaTheme.danger,
      TaskStatus.soon => UgandaTheme.warning,
      TaskStatus.ok => null,
    };
    final progress = task.progress(hours, now).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(top: 12, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (status != TaskStatus.ok) ...[
                Icon(
                    status == TaskStatus.due
                        ? Icons.build_circle
                        : Icons.schedule,
                    size: 18,
                    color: color),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: InkWell(
                  onTap: () => showTaskDialog(context,
                      machineId: task.machineId, task: task),
                  child: Text(task.title, style: theme.textTheme.bodyLarge),
                ),
              ),
              FilledButton.tonal(
                onPressed: () async {
                  await maintenanceService.markDone(task.id);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${task.title}: marked done')));
                },
                child: const Text('Done'),
              ),
            ],
          ),
          Text(
            '${task.intervalText} · ${task.dueText(hours, now)} · last done '
            '${DateFormat('d MMM y').format(task.doneOn)}',
            style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: status == TaskStatus.ok ? null : FontWeight.bold),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              color: color ?? theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// Add a task for [machineId], or edit (or delete) [task].
Future<void> showTaskDialog(BuildContext context,
    {required String machineId, MaintenanceTask? task}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TaskDialog(machineId: machineId, task: task),
  );
}

class _TaskDialog extends StatefulWidget {
  const _TaskDialog({required this.machineId, this.task});

  final String machineId;
  final MaintenanceTask? task;

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  late final _title = TextEditingController(text: widget.task?.title ?? '');
  late final _hours =
      TextEditingController(text: widget.task?.everyHours?.toString() ?? '');
  late final _days =
      TextEditingController(text: widget.task?.everyDays?.toString() ?? '');
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _hours.dispose();
    _days.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final hours = int.tryParse(_hours.text.trim());
    final days = int.tryParse(_days.text.trim());
    if (title.isEmpty) {
      setState(() => _error = 'Enter what needs doing');
      return;
    }
    if ((hours == null || hours <= 0) && (days == null || days <= 0)) {
      setState(() => _error = 'Enter an interval in hours, days, or both');
      return;
    }
    final h = hours != null && hours > 0 ? hours : null;
    final d = days != null && days > 0 ? days : null;
    final existing = widget.task;
    if (existing == null) {
      await maintenanceService.addTask(
          machineId: widget.machineId,
          title: title,
          everyHours: h,
          everyDays: d);
    } else {
      await maintenanceService.updateTask(existing.copyWith(
          title: title, everyHours: () => h, everyDays: () => d));
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return AlertDialog(
      title: Text(widget.task == null ? 'Add task' : 'Edit task'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _title,
            autofocus: widget.task == null,
            decoration: const InputDecoration(labelText: 'What needs doing'),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hours,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: const InputDecoration(labelText: 'Every … hours'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _days,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: const InputDecoration(labelText: 'or … days'),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: const TextStyle(color: UgandaTheme.danger)),
            ),
        ],
      ),
      actions: [
        if (widget.task != null)
          TextButton(
            onPressed: () async {
              await maintenanceService.removeTask(widget.task!.id);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Shown on the Dashboard while maintenance is due.
class MaintenanceDueCard extends StatelessWidget {
  const MaintenanceDueCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: maintenanceService,
      builder: (context, _) {
        final due = maintenanceService.dueTasks;
        if (due.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            color: UgandaTheme.tintedCard(context, UgandaTheme.warning),
            child: ListTile(
              leading:
                  const Icon(Icons.build_circle, color: UgandaTheme.warning),
              title: Text(
                  '${due.length} maintenance task${due.length == 1 ? '' : 's'} due'),
              subtitle: Text(due.map((t) => t.title).take(2).join(' · ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pushNamed(context, '/maintenance'),
            ),
          ),
        );
      },
    );
  }
}
