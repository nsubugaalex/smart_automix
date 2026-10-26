import 'package:flutter/material.dart';
import '../../constants/uedcl_tariffs.dart';
import '../../models/alert_model.dart';
import '../../models/energy_prices.dart';
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

  // Time-of-use, from the bill (shoulder is the standard rate above).
  late bool _touEnabled;
  late final TextEditingController _peakRateController;
  late final TextEditingController _offPeakRateController;
  late int _peakStart, _peakEnd, _offPeakStart, _offPeakEnd;

  // Standby generator fuel cost.
  late final TextEditingController _fuelPriceController;
  late final TextEditingController _litresPerKwhController;

  @override
  void initState() {
    super.initState();
    final tou = tariffService.timeOfUse;
    _touEnabled = tou.enabled;
    _peakRateController =
        TextEditingController(text: tou.peakRate.toStringAsFixed(0));
    _offPeakRateController =
        TextEditingController(text: tou.offPeakRate.toStringAsFixed(0));
    _peakStart = tou.peakStart;
    _peakEnd = tou.peakEnd;
    _offPeakStart = tou.offPeakStart;
    _offPeakEnd = tou.offPeakEnd;
    final generator = tariffService.generator;
    _fuelPriceController = TextEditingController(
        text: generator.fuelPricePerLitre.toStringAsFixed(0));
    _litresPerKwhController =
        TextEditingController(text: '${generator.litresPerKwh}');
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
    _peakRateController.dispose();
    _offPeakRateController.dispose();
    _fuelPriceController.dispose();
    _litresPerKwhController.dispose();
    super.dispose();
  }

  String? _validatePositive(String? value) {
    final number = _parse(value ?? '');
    if (number == null) return 'Enter a number';
    if (number <= 0) return 'Must be greater than 0';
    return null;
  }

  TimeOfUse _timeOfUse() => TimeOfUse(
        enabled: _touEnabled,
        peakRate: _parse(_peakRateController.text) ?? 0,
        offPeakRate: _parse(_offPeakRateController.text) ?? 0,
        peakStart: _peakStart,
        peakEnd: _peakEnd,
        offPeakStart: _offPeakStart,
        offPeakEnd: _offPeakEnd,
      );

  GeneratorCost _generatorCost() => GeneratorCost(
        fuelPricePerLitre: _parse(_fuelPriceController.text)!,
        litresPerKwh: _parse(_litresPerKwhController.text)!,
      );

  static String _hour(int h) => '${h.toString().padLeft(2, '0')}:00';

  Widget _hourPicker(
      String label, int value, bool isEnd, ValueChanged<int> onChanged) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration:
          InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [
        for (var h = isEnd ? 1 : 0; h <= (isEnd ? 24 : 23); h++)
          DropdownMenuItem(value: h, child: Text(_hour(h))),
      ],
      onChanged: (h) {
        if (h != null) setState(() => onChanged(h));
      },
    );
  }

  Widget _window(String title, int start, int end, ValueChanged<int> onStart,
      ValueChanged<int> onEnd) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(child: _hourPicker('$title from', start, false, onStart)),
          const SizedBox(width: 12),
          Expanded(child: _hourPicker('to', end, true, onEnd)),
        ],
      ),
    );
  }

  /// "today", "yesterday" or "N days ago".
  static String _ago(DateTime time) {
    final days = DateTime.now().difference(time).inDays;
    if (days == 0) return 'today';
    if (days == 1) return 'yesterday';
    return '$days days ago';
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
    final timeOfUse = _timeOfUse();
    final touProblem = _touEnabled ? timeOfUse.validate() : null;
    if (touProblem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(touProblem)));
      return;
    }

    final rate = _parse(_rateController.text)!;
    final tariffChanged =
        _category != tariffService.category || rate != tariffService.ratePerKwh;

    await tariffService.confirmTariff(
      category: _category,
      ratePerKwh: rate,
      monthlyFixedCharge: _parse(_fixedChargeController.text) ?? 0,
      dailyCostAlertThreshold: _parse(_costAlertController.text),
    );
    if (timeOfUse.validate() == null) {
      await tariffService.saveTimeOfUse(timeOfUse);
    }
    await tariffService.saveGenerator(_generatorCost());

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
                  color: isStale
                      ? UgandaTheme.tintedCard(context, UgandaTheme.danger,
                          alpha: 20)
                      : null,
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
                                    ? 'Rate last confirmed ${_ago(lastUpdated)} '
                                        '— likely outdated, please check your bill.'
                                    : 'Rate confirmed ${_ago(lastUpdated)}.',
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
                const SizedBox(height: 24),
                Text(
                  'Time-of-use',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('My bill has peak and off-peak rates'),
                  subtitle: const Text(
                    'Prices energy by the hour it was used, and shows what '
                    'running heavy work off-peak would save. The rate above '
                    'is then the shoulder (standard) rate.',
                  ),
                  value: _touEnabled,
                  onChanged: (on) => setState(() => _touEnabled = on),
                ),
                if (_touEnabled) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _peakRateController,
                          validator: _validatePositive,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Peak rate (UGX/kWh)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _offPeakRateController,
                          validator: _validatePositive,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Off-peak rate (UGX/kWh)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  _window('Peak', _peakStart, _peakEnd, (h) => _peakStart = h,
                      (h) => _peakEnd = h),
                  _window('Off-peak', _offPeakStart, _offPeakEnd,
                      (h) => _offPeakStart = h, (h) => _offPeakEnd = h),
                  const SizedBox(height: 8),
                  Text(
                    'Hours not in either window are shoulder. The defaults '
                    'are ERA\'s periods for industrial customers; check them '
                    'and the rates against your bill.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Standby generator',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _fuelPriceController,
                        validator: _validatePositive,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Fuel price (UGX/litre)',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _litresPerKwhController,
                        validator: _validatePositive,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Litres per kWh',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Builder(builder: (context) {
                  final price = _parse(_fuelPriceController.text);
                  final litres = _parse(_litresPerKwhController.text);
                  final perKwh =
                      price != null && litres != null ? price * litres : null;
                  return Text(
                    '${perKwh == null ? '' : 'About ${UgandaTheme.formatUgx(perKwh)} per kWh from the generator. '}'
                    'To measure litres per kWh: fill the tank, note the '
                    'generator kWh on the Energy tab, refill, and divide the '
                    'litres by the kWh used. A lightly loaded generator uses '
                    'more fuel per kWh.',
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                }),
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
