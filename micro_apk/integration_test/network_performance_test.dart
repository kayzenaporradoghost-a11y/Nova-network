import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:micro_apk/main.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('NETWORK on-device startup and accessibility latency benchmark', (tester) async {
    final startup = Stopwatch()..start();
    await tester.pumpWidget(const MicroApp());
    await tester.pump();
    startup.stop();

    final screenRead = Stopwatch()..start();
    final screenReadSamplesMs = <double>[];
    String screenReadStatus = 'not_attempted';
    for (var sample = 0; sample < 10; sample++) {
      final singleRead = Stopwatch()..start();
      try {
        await const MethodChannel('micro/runtime')
            .invokeMethod<dynamic>('phone_screen_read')
            .timeout(const Duration(seconds: 2));
        singleRead.stop();
        screenReadSamplesMs.add(singleRead.elapsedMicroseconds / 1000.0);
        screenReadStatus = 'success';
      } catch (error) {
        screenReadStatus = 'unavailable: $error';
        break;
      }
    }
    screenRead.stop();
    final sortedScreenReads = List<double>.from(screenReadSamplesMs)..sort();
    double percentile(List<double> values, double fraction) {
      if (values.isEmpty) return 0;
      final index = ((values.length - 1) * fraction).ceil().clamp(0, values.length - 1).toInt();
      return values[index];
    }

    final eventWatch = Stopwatch()..start();
    String accessibilityEventStatus = 'timeout_or_accessibility_disabled';
    num? eventAgeMs;
    num? snapshotBuildMs;
    try {
      final event = await const EventChannel('micro/screen_events')
          .receiveBroadcastStream()
          .first
          .timeout(const Duration(seconds: 5));
      eventWatch.stop();
      accessibilityEventStatus = 'received';
      if (event is Map) {
        eventAgeMs = event['eventAgeMs'] as num?;
        snapshotBuildMs = event['snapshotBuildMs'] as num?;
      }
    } catch (_) {
      eventWatch.stop();
    }

    binding.reportData = <String, dynamic>{
      'network_device_benchmark': {
        'startup_first_frame_ms': startup.elapsedMicroseconds / 1000.0,
        'phone_screen_read_total_ms': screenRead.elapsedMicroseconds / 1000.0,
        'phone_screen_read_samples': screenReadSamplesMs.length,
        'phone_screen_read_p50_ms': percentile(sortedScreenReads, 0.50),
        'phone_screen_read_p95_ms': percentile(sortedScreenReads, 0.95),
        'phone_screen_read_status': screenReadStatus,
        'accessibility_event_wait_ms': eventWatch.elapsedMicroseconds / 1000.0,
        'accessibility_event_status': accessibilityEventStatus,
        'accessibility_event_age_ms': eventAgeMs,
        'accessibility_snapshot_build_ms': snapshotBuildMs,
        'device': 'reported by integration_test runner',
        'note': 'Run on the target physical phone with NETWORK Accessibility enabled for meaningful measurements.',
      },
    };
    expect(find.byType(MicroApp), findsOneWidget);
  });
}
