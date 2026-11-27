import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Métricas de baixa sobrecarga. A coleta JSONL persistente só é ativada
/// explicitamente com --dart-define=PERF_TRACE=true.
class AgentPerformanceMetrics {
  AgentPerformanceMetrics._();

  static const bool traceEnabled = bool.fromEnvironment('PERF_TRACE', defaultValue: false);
  static final Map<String, List<int>> _samples = <String, List<int>>{};
  static DateTime? _startedAt;
  static DateTime? _lastRunStartedAt;
  static int _runCount = 0;
  static Directory? _traceDirectory;
  static Future<void> _writeQueue = Future<void>.value();
  static String? _lastWriteError;

  static Future<void> initialize() async {
    if (!traceEnabled || _traceDirectory != null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      _traceDirectory = Directory('${docs.path}/NETWORK/Performance');
      await _traceDirectory!.create(recursive: true);
      _queueEvent({
        'type': 'environment',
        'timestamp': DateTime.now().toIso8601String(),
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'dartVersion': Platform.version,
        'processors': Platform.numberOfProcessors,
        'locale': Platform.localeName,
      });
    } catch (error) {
      _lastWriteError = error.toString();
    }
  }

  static void _queueEvent(Map<String, dynamic> event) {
    if (!traceEnabled) return;
    _writeQueue = _writeQueue.then((_) async {
      try {
        await initialize();
        final dir = _traceDirectory;
        if (dir == null) return;
        final file = File('${dir.path}/perf-trace.jsonl');
        await file.writeAsString(jsonEncode(event) + '\n', mode: FileMode.append, flush: false);
        _lastWriteError = null;
      } catch (error) {
        _lastWriteError = error.toString();
      }
    });
  }

  static void beginRun({String? flow, String? taskId}) {
    final now = DateTime.now();
    _startedAt ??= now;
    _lastRunStartedAt = now;
    _runCount++;
    _queueEvent({
      'type': 'run_start',
      'timestamp': now.toIso8601String(),
      'run': _runCount,
      if (flow != null) 'flow': flow,
      if (taskId != null) 'taskId': taskId,
    });
  }

  static void endRun({required String status, String? flow, String? taskId}) {
    _queueEvent({
      'type': 'run_end',
      'timestamp': DateTime.now().toIso8601String(),
      'status': status,
      if (flow != null) 'flow': flow,
      if (taskId != null) 'taskId': taskId,
    });
  }

  static void event(String name, [Map<String, dynamic> data = const {}]) {
    _queueEvent({
      'type': 'event',
      'timestamp': DateTime.now().toIso8601String(),
      'name': name,
      'data': data,
    });
  }

  static void record(String name, Duration elapsed) =>
      recordMilliseconds(name, elapsed.inMicroseconds / 1000.0);

  static void recordMilliseconds(String name, num milliseconds) {
    if (milliseconds.isNaN || milliseconds.isInfinite || milliseconds < 0) return;
    final micros = (milliseconds * 1000).round();
    final values = _samples.putIfAbsent(name, () => <int>[]);
    values.add(micros);
    if (values.length > 500) values.removeAt(0);
    _queueEvent({
      'type': 'span',
      'timestamp': DateTime.now().toIso8601String(),
      'name': name,
      'durationMs': micros / 1000.0,
    });
  }

  static Future<void> flush() async {
    await _writeQueue;
  }

  static Future<String> exportJsonl() async {
    await flush();
    final dir = _traceDirectory;
    if (dir == null) {
      return traceEnabled
          ? 'O arquivo de rastreamento ainda não foi criado. Execute uma tarefa com PERF_TRACE habilitado.'
          : 'Rastreamento persistente desativado. Compile com --dart-define=PERF_TRACE=true.';
    }
    final file = File('${dir.path}/perf-trace.jsonl');
    if (!await file.exists()) return 'Ainda não há eventos persistidos.';
    return file.readAsString();
  }

  static String get traceFilePath =>
      _traceDirectory == null ? 'Rastreamento não inicializado' : '${_traceDirectory!.path}/perf-trace.jsonl';

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
        'lastMs': sorted.isEmpty ? 0 : entry.value.last / 1000.0,
        'p50Ms': _percentile(sorted, 0.50) / 1000.0,
        'p95Ms': _percentile(sorted, 0.95) / 1000.0,
        'p99Ms': _percentile(sorted, 0.99) / 1000.0,
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
      'traceEnabled': traceEnabled,
      'traceFile': traceFilePath,
      'traceWriteError': _lastWriteError,
      'note': 'Latências observadas neste processo/dispositivo; p50/p95/p99 são calculados por operação e dependem do número de amostras.',
    };
  }
}
