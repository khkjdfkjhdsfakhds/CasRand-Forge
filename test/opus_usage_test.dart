import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';

void main() {
  test('preserves a boosted allowance above 100%', () {
    final usage = OpusUsage(
      percent: 170,
      isNegative: false,
      secondsPerPercent: 6048,
      observedAt: DateTime(2026, 8, 21),
    );

    expect(usage.visiblePercent, 170);
  });

  test('projected usage can refill past 100%', () {
    final observedAt = DateTime(2026, 8, 21);
    final usage = OpusUsage(
      percent: 99,
      isNegative: false,
      secondsPerPercent: 100,
      observedAt: observedAt,
    );

    expect(
      usage.projectedAt(observedAt.add(const Duration(seconds: 200))).percent,
      101,
    );
  });
}
