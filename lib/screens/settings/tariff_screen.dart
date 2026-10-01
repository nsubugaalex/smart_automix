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
  late final TextEditingController _rateController;
  late final TextEditingController _fixedChargeController;
  late final TextEditingController _costAlertController;

  @override
  void initState() {
    super.initState();
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

  Future<void> _save() async {
    final rate = double.tryParse(_rateController.text);
    final charge = double.tryParse(_fixedChargeController.text);
    final threshold = double.tryParse(_costAlertController.text);

    if (rate != null) await tariffService.setRatePerKwh(rate);
    if (charge != null) await tariffService.setMonthlyFixedCharge(charge);
    await tariffService.setDailyCostAlertThreshold(
      _costAlertController.text.trim().isEmpty ? null : threshold,
    );

    await alertService.add(
      title: 'Tariff updated',
      message: 'Now billing as ${tariffService.category.label} at '
          '${UgandaTheme.formatUgx(tariffService.ratePerKwh)}/kWh.',
      severity: AlertSeverity.info,
    );
    await alertService.checkTariffHealth();

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
                        color: isStale ? UgandaTheme.danger : UgandaTheme.running,
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
                groupValue: tariffService.category,
                onChanged: (value) {
                  if (value == null) return;
                  tariffService.setCategory(value);
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
              TextField(
                controller: _rateController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Rate per kWh (UGX)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _fixedChargeController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Monthly fixed charge (UGX, optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _costAlertController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
        );
      },
    );
  }
}
