import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class RuleSetDiagnosticsEntry {
  RuleSetDiagnosticsEntry({
    required this.tag,
    required this.activeUrl,
    required this.localPath,
    required this.lastSuccessAt,
    required this.lastError,
    required this.usedCache,
    required this.fallbackUsed,
  });

  final String tag;
  final String? activeUrl;
  final String? localPath;
  final String? lastSuccessAt;
  final String? lastError;
  final bool usedCache;
  final bool fallbackUsed;

  factory RuleSetDiagnosticsEntry.fromJson(Map<String, dynamic> json) {
    return RuleSetDiagnosticsEntry(
      tag: json['tag']?.toString() ?? '',
      activeUrl: json['active_url']?.toString(),
      localPath: json['local_path']?.toString(),
      lastSuccessAt: json['last_success_at']?.toString(),
      lastError: json['last_error']?.toString(),
      usedCache: json['used_cache'] == true,
      fallbackUsed: json['fallback_used'] == true,
    );
  }
}

class RuleSetDiagnosticsSnapshot {
  RuleSetDiagnosticsSnapshot({required this.generatedAt, required this.entries});

  final String? generatedAt;
  final List<RuleSetDiagnosticsEntry> entries;
}

class RuleSetDiagnosticsRepository {
  RuleSetDiagnosticsRepository({required this.dataDirPath});

  final String dataDirPath;

  Future<RuleSetDiagnosticsSnapshot?> readSnapshot() async {
    final file = File('$dataDirPath/rule-set-metadata.json');
    if (!await file.exists()) return null;
    try {
      final jsonMap = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final dynamic rawRuleSets = jsonMap['rule_sets'];
      final List<dynamic> parsedRuleSets = switch (rawRuleSets) {
        final List<dynamic> list => list,
        final String value => _tryDecodeRuleSetsString(value),
        _ => const <dynamic>[],
      };
      final list = parsedRuleSets
          .whereType<Map<String, dynamic>>()
          .map(RuleSetDiagnosticsEntry.fromJson)
          .toList(growable: false);
      return RuleSetDiagnosticsSnapshot(generatedAt: jsonMap['generated_at']?.toString(), entries: list);
    } catch (_) {
      return null;
    }
  }

  List<dynamic> _tryDecodeRuleSetsString(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return const <dynamic>[];
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is List<dynamic> ? decoded : const <dynamic>[];
    } catch (_) {
      return const <dynamic>[];
    }
  }
}

final ruleSetDiagnosticsRepositoryProvider = Provider<RuleSetDiagnosticsRepository>((ref) {
  final appDirs = ref.watch(appDirectoriesProvider).requireValue;
  return RuleSetDiagnosticsRepository(dataDirPath: appDirs.workingDir.path + '/data');
});
