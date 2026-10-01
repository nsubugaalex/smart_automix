import 'package:flutter/material.dart';
import '../../constants/uedcl_tariffs.dart';
import '../../models/alert_model.dart';
import '../../services/alert_service.dart';
import '../../services/tariff_service.dart';
import '../../widgets/common/responsive_page.dart';
import '../../widgets/custom/uganda_theme.dart';

/// Lets the facility operator pick their UEDCL billing category and enter
/// the rate currently shown on their UEDCL bill, since ERA tariffs change
/// quarterly and this app has no live feed into UEDCL's billing system.
/// Body-only (no Scaffold/AppBar) — hosted inside [MainShell].
class TariffBody extends StatefulWidget {
  const TariffBody({super.key});

  @override
  State<TariffBody> createState() => _TariffBodyState();
}

class _TariffBodyState extends State<TariffBody> {
  final _formKey = GlobalKey<FormState>();

  /// Category picked on screen; only applied to [tariffService] on Save.
  late UedclTariffCategory _category;
  late final TextEditingController _rateController;
  late final TextEditingController _fixedChargeController;
  late final TextEditingController _costAlertController;

  @override
  void initState() {
    super.initState();
    _category = tariffService.category;
    _rateController = TextEditingController(
      text: tariffService.ratePerKwh.toStringAsFixed(0),
    );
    _fixedChargeController = TextEditingController(
      text: tariffService.monthlyFixedCharge.toStringAsFixed(0),
    );
    _costAlertController = TextEditingController(
      text: tariffService.dailyCostAlertThreshold?.toStringAsFixed(0) ?? '',
    );
  }

  @override
  void dispose() {
    _rateController.dispose();
    _fixedChargeController.dispose();
    _costAlertController.dispose();
    super.dispose();
  }

  static double? _parse(String text) => double.tryParse(text.trim());

  String? _validateRate(String? value) {
    final rate = _parse(value ?? '');
    if (rate == null) return 'Enter the rate from your UEDCL bill';
    if (rate <= 0) return 'Rate must be greater than 0';
    return null;
  }

  String? _validateFixedCharge(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final charge = _parse(value);
    if (charge == null) return 'Enter a number';
    if (charge < 0) return 'Cannot be negative';
    return null;
  }

  String? _validateThreshold(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final threshold = _parse(value);
    if (threshold == null) return 'Enter a number';
    if (threshold <= 0) return 'Must be greater than 0';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final rate = _parse(_rateController.text)!;
    final tariffChanged =
        _category != tariffService.category || rate != tariffService.ratePerKwh;

    await tariffService.confirmTariff(
      category: _category,
      ratePerKwh: rate,
      monthlyFixedCharge: _parse(_fixedChargeController.text) ?? 0,
      dailyCostAlertThreshold: _parse(_costAlertController.text),
    );

    if (tariffChanged) {
      await alertService.add(
        title: 'Tariff updated',
        message: 'Now billing as ${tariffService.category.label} at '
            '${UgandaTheme.formatUgx(tariffService.ratePerKwh)}/kWh.',
        severity: AlertSeverity.info,
      );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tariff settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: tariffService,
      builder: (context, _) {
        final isStale = tariffService.isStale;
        final lastUpdated = tariffService.lastUpdated;

        return ResponsivePage(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Card(
                  color: UgandaTheme.black,
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: UgandaTheme.yellow),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'UEDCL/ERA tariffs are adjusted quarterly. The rates '
                            'below are reference defaults only — enter the rate '
                            'shown on your current UEDCL bill for accurate cost '
                            'estimates.',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  color: isStale ? UgandaTheme.danger.withAlpha(20) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          isStale ? Icons.warning_amber : Icons.check_circle,
                          color: isStale
                              ? UgandaTheme.danger
                              : UgandaTheme.running,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            lastUpdated == null
                                ? 'Rate never confirmed — save below to confirm it.'
                                : isStale
                                    ? "Rate last confirmed ${DateTime.now().difference(lastUpdated).inDays} "
                                        'days ago — likely outdated, please check your bill.'
                                    : 'Rate confirmed ${DateTime.now().difference(lastUpdated).inDays} '
                                        'day(s) ago.',
                            style: TextStyle(
                              color: isStale ? UgandaTheme.danger : null,
                              fontWeight: isStale ? FontWeight.bold : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Billing category',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                RadioGroup<UedclTariffCategory>(
                  groupValue: _category,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _category = value);
                    _rateController.text =
                        value.defaultRatePerKwh.toStringAsFixed(0);
                  },
                  child: Column(
                    children: UedclTariffCategory.values.map((category) {
                      return RadioListTile<UedclTariffCategory>(
                        value: category,
                        title: Text(category.label),
                        subtitle: Text(category.description),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Current rate',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _rateController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Rate per kWh (UGX)',
                    helperText: 'Picking a category fills in a placeholder '
                        'default — replace it with the rate on your bill.',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateRate,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _fixedChargeController,
                  validator: _validateFixedCharge,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Monthly fixed charge (UGX, optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _costAlertController,
                  validator: _validateThreshold,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Alert me if daily cost exceeds (UGX, optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
