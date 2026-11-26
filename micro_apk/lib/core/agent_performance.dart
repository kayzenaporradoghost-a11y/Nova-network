/// Low-overhead in-memory latency recorder. No disk/network work occurs on hot paths.
class AgentPerformanceMetrics {
  AgentPerformanceMetrics._();

  static final Map<String, List<int>> _samples = <String, List<int>>{};
  static DateTime? _startedAt;
  static DateTime? _lastRunStartedAt;
  static int _runCount = 0;

  static void beginRun() {
    final now = DateTime.now();
    _startedAt ??= now;
    _lastRunStartedAt = now;
    _runCount++;
  }

  static void record(String name, Duration elapsed) => recordMilliseconds(name, elapsed.inMicroseconds / 1000.0);

  static void recordMilliseconds(String name, num milliseconds) {
    if (milliseconds.isNaN || milliseconds.isInfinite || milliseconds < 0) return;
    final values = _samples.putIfAbsent(name, () => <int>[]);
    values.add((milliseconds * 1000).round());
    if (values.length > 500) values.removeAt(0);
  }

  static int _percentile(List<int> sorted, double percentile) {
    if (sorted.isEmpty) return 0;
    final index = ((sorted.length - 1) * percentile).ceil().clamp(0, sorted.length - 1).toInt();
    return sorted[index];
  }

  static Map<String, dynamic> snapshot() {
    final result = <String, dynamic>{};
    for (final entry in _samples.entries) {
      final sorted = List<int>.from(entry.value)..sort();
      result[entry.key] = {
        'count': sorted.length,
        'lastMs': sorted.isEmpty ? 0 : sorted.last / 1000.0,
        'p50Ms': _percentile(sorted, 0.50) / 1000.0,
        'p95Ms': _percentile(sorted, 0.95) / 1000.0,
        'minMs': sorted.isEmpty ? 0 : sorted.first / 1000.0,
        'maxMs': sorted.isEmpty ? 0 : sorted.last / 1000.0,
      };
    }
    return {
      'startedAt': _startedAt?.toIso8601String(),
      'lastRunStartedAt': _lastRunStartedAt?.toIso8601String(),
      'runCount': _runCount,
      'sampleCount': _samples.values.fold<int>(0, (sum, values) => sum + values.length),
      'metrics': result,
      'note': 'Latências observadas neste processo/dispositivo; p50/p95 exigem amostras suficientes.',
    };
  }
}
