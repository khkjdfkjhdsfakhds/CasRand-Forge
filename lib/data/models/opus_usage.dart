class OpusUsage {
  final double percent;
  final bool isNegative;
  final double secondsPerPercent;
  final DateTime observedAt;

  const OpusUsage({
    required this.percent,
    required this.isNegative,
    required this.secondsPerPercent,
    required this.observedAt,
  });

  /// Percentage reported by NovelAI for the remaining allowance.
  ///
  /// Opus can grant temporary boosts, so the value may legitimately exceed
  /// 100%. Negative usage is still represented as zero for display.
  double get visiblePercent =>
      isNegative ? 0 : percent.clamp(0, double.infinity).toDouble();

  double get refillPercentPerHour =>
      secondsPerPercent > 0 ? 3600 / secondsPerPercent : 0;

  OpusUsage projectedAt(DateTime now) {
    if (isNegative || secondsPerPercent <= 0 || !now.isAfter(observedAt)) {
      return this;
    }
    final elapsedSeconds = now.difference(observedAt).inMilliseconds / 1000;
    return OpusUsage(
      percent: (percent + elapsedSeconds / secondsPerPercent)
          .clamp(0, double.infinity)
          .toDouble(),
      isNegative: false,
      secondsPerPercent: secondsPerPercent,
      observedAt: now,
    );
  }
}
