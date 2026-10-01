import 'package:flutter/material.dart';

/// Radial gauge showing current total load against a configured maximum
/// demand threshold (e.g. the facility's UEDCL supply/breaker capacity),
/// so an operator can see at a glance how close they are to tripping the
/// main breaker or entering a higher demand charge band.
class ConsumptionGauge extends StatelessWidget {
  const ConsumptionGauge({
    super.key,
    required this.currentWatts,
    required this.maxWatts,
    this.size = 160,
  });

  final double currentWatts;
  final double maxWatts;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ratio = maxWatts <= 0 ? 0.0 : (currentWatts / maxWatts).clamp(0.0, 1.0);
    final isOverloaded = currentWatts > maxWatts && maxWatts > 0;
    final color = isOverloaded
        ? Colors.red
        : (ratio > 0.8 ? Colors.orange : Colors.green);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: ratio,
              strokeWidth: 10,
              backgroundColor: Colors.grey.withAlpha(60),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${(currentWatts / 1000).toStringAsFixed(2)} kW',
                style: TextStyle(
                  fontSize: size * 0.13,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                maxWatts > 0
                    ? 'of ${(maxWatts / 1000).toStringAsFixed(1)} kW max'
                    : 'load',
                style: TextStyle(fontSize: size * 0.08, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
