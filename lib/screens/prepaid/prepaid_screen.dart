import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../models/prepaid.dart';
import '../../services/prepaid_service.dart';
import '../../services/tariff_service.dart';
import '../../widgets/custom/uganda_theme.dart';

final _units = NumberFormat('#,##0');
String _kwh(double v) => '${_units.format(v.round())} kWh';

/// "about 3 days (until Sat 25 Oct)", or "less than a day".
String creditLasts(PrepaidBalance b, DateTime now) {
  final days = b.daysLeft;
  if (days == null) return 'usual daily use not known yet';
  if (days < 1) return 'less than a day at your usual use';
  final until = now.add(Duration(minutes: (days * 24 * 60).round()));
  return 'about ${days.floor()} day${days.floor() == 1 ? '' : 's'} '
      '(until ${DateFormat('EEE d MMM').format(until)})';
}

/// Prepaid (Yaka) credit: balance, tokens bought and meter readings.
class PrepaidScreen extends StatelessWidget {
  const PrepaidScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Yaka credit')),
      body: ListenableBuilder(
        listenable: Listenable.merge([prepaidService, tariffService]),
        builder: (context, _) {
          final theme = Theme.of(context);
          final now = DateTime.now();
          final b = prepaidService.balance;
          final low = prepaidService.isLow;
          final price = prepaidService.averagePrice;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('This site has a prepaid Yaka meter'),
                value: prepaidService.enabled,
                onChanged: (on) => prepaidService.configure(enabled: on),
              ),
              if (prepaidService.enabled) ...[
                Card(
                  color: low
                      ? UgandaTheme.tintedCard(context, UgandaTheme.danger)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: b == null
                        ? Text(
                            'Enter the units left that the Yaka meter shows '
                            'now. The app then keeps track from the energy '
                            'the panel measures and the tokens you add.',
                            style: theme.textTheme.bodyLarge)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Estimated credit left',
                                  style: theme.textTheme.labelLarge),
                              Text(_kwh(b.units < 0 ? 0 : b.units),
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              Row(
                                children: [
                                  if (low) ...[
                                    const Icon(Icons.warning_amber,
                                        color: UgandaTheme.danger, size: 18),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(creditLasts(b, now),
                                        style: theme.textTheme.bodyLarge),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${b.units < 0 ? 'The estimate has run below zero: read the meter again. ' : ''}'
                                'From the meter reading on '
                                '${DateFormat('d MMM, HH:mm').format(b.since)}, '
                                '${_kwh(b.usedKwh)} used since '
                                '(${b.measured ? 'measured by the panel' : 'estimated from machine ratings'}). '
                                'Read the Yaka meter now and then to keep it '
                                'accurate.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _purchaseDialog(context),
                      icon: const Icon(Icons.add_card),
                      label: const Text('I bought a token'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _readingDialog(context),
                      icon: const Icon(Icons.speed),
                      label: const Text('Enter meter reading'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.pin_outlined),
                  title: Text(prepaidService.meterNumber.isEmpty
                      ? 'Yaka meter number'
                      : prepaidService.meterNumber),
                  subtitle: const Text(
                      'For buying tokens by mobile money or at an agent'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (prepaidService.meterNumber.isNotEmpty)
                        IconButton(
                          tooltip: 'Copy',
                          icon: const Icon(Icons.copy),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(
                                text: prepaidService.meterNumber));
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Meter number copied')));
                          },
                        ),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit),
                        onPressed: () => _meterNumberDialog(context),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Warn me when credit is below'),
                  trailing: DropdownButton<int>(
                    value: prepaidService.warnDays,
                    items: [
                      for (final d in [1, 2, 3, 5, 7])
                        DropdownMenuItem(
                            value: d,
                            child: Text('$d day${d == 1 ? '' : 's'}')),
                    ],
                    onChanged: (d) =>
                        prepaidService.configure(enabled: true, warnDays: d),
                  ),
                ),
                if (price != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(
                      'You paid ${UgandaTheme.formatUgx(price)} per unit on '
                      'average (taxes and charges included); the Tariff tab '
                      'rate is ${UgandaTheme.formatUgx(tariffService.ratePerKwh)}/kWh.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const Divider(),
                Text('History', style: theme.textTheme.titleMedium),
                if (prepaidService.entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('Nothing recorded yet.'),
                  ),
                for (final e in prepaidService.entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(e.kind == PrepaidEntryKind.purchase
                        ? Icons.add_card
                        : Icons.speed),
                    title: Text(e.kind == PrepaidEntryKind.purchase
                        ? 'Token: +${_kwh(e.units)}'
                            '${e.amountUgx == null ? '' : ' for ${UgandaTheme.formatUgx(e.amountUgx!)}'}'
                        : 'Meter showed ${_kwh(e.units)}'),
                    subtitle:
                        Text(DateFormat('EEE d MMM y, HH:mm').format(e.at)),
                    trailing: IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final removed = await prepaidService.remove(e.id);
                        if (removed == null || !context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: const Text('Entry deleted'),
                          action: SnackBarAction(
                            label: 'Undo',
                            onPressed: () => prepaidService.restore(removed),
                          ),
                        ));
                      },
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  static double? _number(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', ''));

  Future<void> _purchaseDialog(BuildContext context) async {
    final units = TextEditingController();
    final amount = TextEditingController();
    final after = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Token bought'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _numberField(units, 'Units on the receipt (kWh)',
                  autofocus: true),
              _numberField(amount, 'Amount paid (UGX, optional)'),
              _numberField(after, 'Meter shows after loading (optional)'),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!,
                      style: const TextStyle(color: UgandaTheme.danger)),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final u = _number(units);
                if (u == null || u <= 0) {
                  setState(() => error = 'Enter the units from the receipt');
                  return;
                }
                await prepaidService.addPurchase(
                  units: u,
                  amountUgx: _number(amount),
                  meterShowsAfter: _number(after),
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _readingDialog(BuildContext context) async {
    final units = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Meter reading'),
        content: _numberField(units, 'Units left on the Yaka meter (kWh)',
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final u = _number(units);
              if (u == null || u < 0) return;
              await prepaidService.addReading(u);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _meterNumberDialog(BuildContext context) async {
    final number = TextEditingController(text: prepaidService.meterNumber);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yaka meter number'),
        content: TextField(
          controller: number,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]'))
          ],
          decoration: const InputDecoration(
              helperText: 'As printed on the meter or a token receipt'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await prepaidService.configure(
                  enabled: true, meterNumber: number.text);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  static Widget _numberField(TextEditingController c, String label,
          {bool autofocus = false}) =>
      TextField(
        controller: c,
        autofocus: autofocus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      );
}

/// Credit summary for the Dashboard, while prepaid tracking is on.
class PrepaidSummaryCard extends StatelessWidget {
  const PrepaidSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: prepaidService,
      builder: (context, _) {
        if (!prepaidService.enabled) return const SizedBox.shrink();
        final b = prepaidService.balance;
        final low = prepaidService.isLow;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Card(
            color: low
                ? UgandaTheme.tintedCard(context, UgandaTheme.danger)
                : null,
            child: ListTile(
              leading: Icon(low ? Icons.warning_amber : Icons.bolt,
                  color: low ? UgandaTheme.danger : null),
              title: Text(b == null
                  ? 'Yaka credit: enter a meter reading'
                  : 'Yaka credit: ${_kwh(b.units < 0 ? 0 : b.units)}'),
              subtitle: b == null
                  ? null
                  : Text('${low ? 'Running low: ' : ''}'
                      '${creditLasts(b, DateTime.now())}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pushNamed(context, '/prepaid'),
            ),
          ),
        );
      },
    );
  }
}
