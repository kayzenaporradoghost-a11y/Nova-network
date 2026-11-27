import 'package:flutter_test/flutter_test.dart';
import 'package:micro_apk/core/agent_performance.dart';

void main() {
  test('latency recorder reports p50 and p95 and resets between runs', () {
    AgentPerformanceMetrics.beginRun();
    for (var value = 1; value <= 100; value++) {
      AgentPerformanceMetrics.recordMilliseconds('unit.test', value);
    }
    final report = AgentPerformanceMetrics.snapshot();
    final metric = (report['metrics'] as Map<String, dynamic>)['unit.test'] as Map<String, dynamic>;
    expect(metric['count'], 100);
    expect(metric['p50Ms'], greaterThan(49));
    expect(metric['p95Ms'], greaterThanOrEqualTo(95));
    expect(metric['p99Ms'], greaterThanOrEqualTo(99));
    AgentPerformanceMetrics.beginRun();
    final retained = AgentPerformanceMetrics.snapshot();
    expect(retained['sampleCount'], 100);
    expect(retained['runCount'], 2);
  });
}
