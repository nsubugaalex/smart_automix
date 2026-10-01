import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

class EnergyDataPoint {
  final DateTime timestamp;
  final double power;

  EnergyDataPoint({
    required this.timestamp,
    required this.power,
  });
}

class EnergyChartWidget extends StatelessWidget {
  final List<EnergyDataPoint> data;

  const EnergyChartWidget({
    super.key,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 250,
      child: SfCartesianChart(
        title: const ChartTitle(text: 'Energy Consumption'),
        primaryXAxis: DateTimeAxis(
          title: const AxisTitle(text: 'Time'),
          dateFormat: DateFormat.Hm(),
        ),
        primaryYAxis: const NumericAxis(
          title: AxisTitle(text: 'Power (W)'),
        ),
        series: <CartesianSeries>[
          LineSeries<EnergyDataPoint, DateTime>(
            dataSource: data,
            xValueMapper: (EnergyDataPoint point, _) => point.timestamp,
            yValueMapper: (EnergyDataPoint point, _) => point.power,
            markerSettings: const MarkerSettings(
              isVisible: true,
            ),
          ),
        ],
      ),
    );
  }
}