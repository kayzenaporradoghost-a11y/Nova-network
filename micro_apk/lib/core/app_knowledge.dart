import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small on-device library of verified app workflows.
/// Entries are hints, never executable macros: every action is re-observed
/// and revalidated by the live accessibility controller before execution.
class AppKnowledgeStore {
  static const storageKey = 'network_app_knowledge_v1';
  static const maxEntries = 80;
  static const maxSteps = 12;

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9À-ÿ]+'), ' ')
      .trim();

  Future<List<Map<String, dynamic>>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded.whereType<Map>().map((item) =>
          Map<String, dynamic>.from(item)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<Map<String, dynamic>> save({
    required String packageName,
    required String appName,
    required String task,
    required List<String> steps,
    required bool verified,
  }) async {
    final package = packageName.trim();
    final title = task.trim();
    final cleanSteps = steps.map((step) => step.trim())
        .where((step) => step.isNotEmpty).take(maxSteps).toList();
    if (package.isEmpty || package.length > 200) {
      throw ArgumentError('Pacote Android inválido.');
    }
    if (title.isEmpty || title.length > 240 || cleanSteps.isEmpty) {
      throw ArgumentError('Informe a tarefa e ao menos uma etapa reutilizável.');
    }
    if (!verified) {
      throw StateError('Só é possível guardar um fluxo depois de verificar o resultado real na tela.');
    }

    final entries = await _read();
    final key = '${package.toLowerCase()}|${_normalize(title)}';
    final existingIndex = entries.indexWhere((entry) =>
        '${entry['package']}|${_normalize(entry['task']?.toString() ?? '')}' == key);
    final previous = existingIndex >= 0 ? entries.removeAt(existingIndex) : null;
    final entry = <String, dynamic>{
      'package': package,
      'appName': appName.trim().isEmpty ? package : appName.trim(),
      'task': title,
      'steps': cleanSteps,
      'verified': true,
      'successCount': ((previous?['successCount'] as num?)?.toInt() ?? 0) + 1,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    entries.insert(0, entry);
    if (entries.length > maxEntries) entries.removeRange(maxEntries, entries.length);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(entries));
    return Map<String, dynamic>.from(entry);
  }

  Future<List<Map<String, dynamic>>> search({
    required String packageName,
    required String task,
    int limit = 4,
  }) async {
    final package = packageName.trim().toLowerCase();
    if (package.isEmpty) return <Map<String, dynamic>>[];
    final terms = _normalize(task).split(' ').where((term) => term.length > 2).toSet();
    final matches = <({Map<String, dynamic> entry, int score})>[];
    for (final entry in await _read()) {
      if ((entry['package']?.toString() ?? '').toLowerCase() != package ||
          entry['verified'] != true) continue;
      final searchable = _normalize('${entry['task'] ?? ''} ${(entry['steps'] as List? ?? const []).join(' ')}');
      final score = terms.fold<int>(0, (sum, term) =>
          sum + (searchable.split(term).length - 1));
      matches.add((entry: entry, score: score));
    }
    matches.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return ((b.entry['successCount'] as num?)?.toInt() ?? 0)
          .compareTo((a.entry['successCount'] as num?)?.toInt() ?? 0);
    });
    return matches.take(limit.clamp(1, 10))
        .map((match) => Map<String, dynamic>.from(match.entry)..['matchScore'] = match.score)
        .toList();
  }

  Future<List<Map<String, dynamic>>> list({int limit = 80}) async {
    return (await _read()).take(limit.clamp(1, maxEntries)).toList();
  }
}
