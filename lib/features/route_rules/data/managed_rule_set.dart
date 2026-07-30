import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

enum ManagedRuleAction { direct, vpn, block }

enum ManagedRulePreset { russia, global, all }

@immutable
class ManagedRuleSetMetadata {
  const ManagedRuleSetMetadata({
    required this.id,
    required this.version,
    required this.source,
    required this.generatedAt,
    required this.expiresAt,
    required this.checksum,
    required this.formatVersion,
    required this.domainCount,
    required this.cidrCount,
    required this.priority,
    required this.action,
    required this.applicablePreset,
    this.signature,
  });

  final String id;
  final String version;
  final String source;
  final DateTime generatedAt;
  final DateTime expiresAt;
  final String checksum;
  final String? signature;
  final int formatVersion;
  final int domainCount;
  final int cidrCount;
  final int priority;
  final ManagedRuleAction action;
  final ManagedRulePreset applicablePreset;

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'source': source,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'checksum': checksum,
    if (signature != null) 'signature': signature,
    'formatVersion': formatVersion,
    'domainCount': domainCount,
    'cidrCount': cidrCount,
    'priority': priority,
    'action': action.name.toUpperCase(),
    'applicablePreset': applicablePreset.name,
  };

  factory ManagedRuleSetMetadata.fromJson(Map<String, dynamic> json) {
    return ManagedRuleSetMetadata(
      id: json['id'] as String,
      version: json['version'] as String,
      source: json['source'] as String,
      generatedAt: DateTime.parse(json['generatedAt'] as String).toUtc(),
      expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
      checksum: (json['checksum'] as String).toLowerCase(),
      signature: json['signature'] as String?,
      formatVersion: json['formatVersion'] as int,
      domainCount: json['domainCount'] as int,
      cidrCount: json['cidrCount'] as int,
      priority: json['priority'] as int,
      action: ManagedRuleAction.values.byName((json['action'] as String).toLowerCase()),
      applicablePreset: ManagedRulePreset.values.byName(json['applicablePreset'] as String),
    );
  }
}

@immutable
class ManagedRuleSet {
  const ManagedRuleSet({required this.metadata, required this.domainSuffixes, required this.ipCidrs});

  final ManagedRuleSetMetadata metadata;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;

  Map<String, Object?> get payload => {'domainSuffix': domainSuffixes, 'ipCidr': ipCidrs};

  Map<String, Object?> toJson() => {'metadata': metadata.toJson(), 'payload': payload};

  factory ManagedRuleSet.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'] as Map<String, dynamic>;
    return ManagedRuleSet(
      metadata: ManagedRuleSetMetadata.fromJson(json['metadata'] as Map<String, dynamic>),
      domainSuffixes: List<String>.unmodifiable((payload['domainSuffix'] as List).cast<String>()),
      ipCidrs: List<String>.unmodifiable((payload['ipCidr'] as List).cast<String>()),
    );
  }
}

class RuleSetValidationException implements Exception {
  const RuleSetValidationException(this.message);

  final String message;

  @override
  String toString() => 'RuleSetValidationException: $message';
}

class ManagedRuleSetNormalizer {
  const ManagedRuleSetNormalizer();

  Future<ManagedRuleSet> compile({
    required String id,
    required String version,
    required String source,
    required DateTime generatedAt,
    required DateTime expiresAt,
    required int priority,
    required ManagedRuleAction action,
    required ManagedRulePreset applicablePreset,
    required Iterable<String> domainInput,
    required Iterable<String> cidrInput,
    String? signature,
  }) async {
    final domains = SplayTreeSet<String>();
    final cidrs = SplayTreeSet<String>();
    for (final raw in domainInput) {
      final normalized = normalizeDomain(raw);
      if (normalized != null) domains.add(normalized);
    }
    for (final raw in cidrInput) {
      final normalized = normalizeCidr(raw);
      if (normalized != null) cidrs.add(normalized);
    }
    final payload = <String, Object?>{
      'domainSuffix': domains.toList(growable: false),
      'ipCidr': cidrs.toList(growable: false),
    };
    final checksum = await checksumForPayload(payload);
    return ManagedRuleSet(
      metadata: ManagedRuleSetMetadata(
        id: id,
        version: version,
        source: source,
        generatedAt: generatedAt.toUtc(),
        expiresAt: expiresAt.toUtc(),
        checksum: checksum,
        signature: signature,
        formatVersion: 1,
        domainCount: domains.length,
        cidrCount: cidrs.length,
        priority: priority,
        action: action,
        applicablePreset: applicablePreset,
      ),
      domainSuffixes: List.unmodifiable(domains),
      ipCidrs: List.unmodifiable(cidrs),
    );
  }

  String? normalizeDomain(String raw) {
    var value = _stripComment(raw).trim().toLowerCase();
    if (value.isEmpty) return null;
    value = value.replaceFirst(RegExp(r'^\|\|'), '');
    value = value.replaceFirst(RegExp(r'^\*\.'), '');
    value = value.replaceFirst(RegExp(r'^\.+'), '');
    value = value.replaceFirst(RegExp(r'\^+$'), '');
    if (value.contains('://')) {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.host.isEmpty) {
        throw const RuleSetValidationException('invalid domain URL');
      }
      value = uri.host.toLowerCase();
    } else {
      value = value.split('/').first.split(':').first;
    }
    value = value.replaceFirst(RegExp(r'\.+$'), '');
    if (value.isEmpty ||
        value.length > 253 ||
        value.contains(RegExp(r'[\s@]')) ||
        value.split('.').any((label) => label.isEmpty || label.length > 63)) {
      throw const RuleSetValidationException('invalid domain');
    }
    return value;
  }

  String? normalizeCidr(String raw) {
    final value = _stripComment(raw).trim().toLowerCase();
    if (value.isEmpty) return null;
    final parts = value.split('/');
    if (parts.length != 2) throw const RuleSetValidationException('CIDR prefix is required');
    final address = InternetAddress.tryParse(parts[0]);
    final prefix = int.tryParse(parts[1]);
    if (address == null || prefix == null) {
      throw const RuleSetValidationException('invalid CIDR');
    }
    final maxPrefix = address.type == InternetAddressType.IPv4 ? 32 : 128;
    if (prefix < 0 || prefix > maxPrefix) {
      throw const RuleSetValidationException('invalid CIDR prefix');
    }
    return '${address.address}/$prefix';
  }

  Future<String> checksumForPayload(Map<String, Object?> payload) async {
    final digest = await Sha256().hash(utf8.encode(jsonEncode(payload)));
    return digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  String _stripComment(String value) => value.replaceFirst(RegExp(r'(^|\s)[#;].*$'), '');
}

class ManagedRuleSetStore {
  ManagedRuleSetStore({
    required this.directory,
    this.now = DateTime.now,
    this.normalizer = const ManagedRuleSetNormalizer(),
  });

  final Directory directory;
  final DateTime Function() now;
  final ManagedRuleSetNormalizer normalizer;

  Future<ManagedRuleSet?> readLastKnownGood(String id) async {
    final file = File(_path(id));
    if (!await file.exists()) return null;
    return _decodeAndVerify(await file.readAsString(), rejectExpired: false);
  }

  Future<ManagedRuleSet> install(ManagedRuleSet candidate) async {
    await _verify(candidate, rejectExpired: true);
    await directory.create(recursive: true);
    final target = File(_path(candidate.metadata.id));
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.lkg');
    await temporary.writeAsString(jsonEncode(candidate.toJson()), flush: true);
    await _decodeAndVerify(await temporary.readAsString(), rejectExpired: true);
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (await target.exists()) await target.delete();
      if (await backup.exists()) await backup.rename(target.path);
      rethrow;
    }
    return candidate;
  }

  Future<ManagedRuleSet> update(String id, Future<String> Function() fetch) async {
    final raw = await fetch();
    final decoded = await _decodeAndVerify(raw, rejectExpired: true);
    if (decoded.metadata.id != id) {
      throw const RuleSetValidationException('rule-set id mismatch');
    }
    return install(decoded);
  }

  Future<ManagedRuleSet> _decodeAndVerify(String raw, {required bool rejectExpired}) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const RuleSetValidationException('root must be an object');
    }
    final result = ManagedRuleSet.fromJson(decoded);
    await _verify(result, rejectExpired: rejectExpired);
    return result;
  }

  Future<void> _verify(ManagedRuleSet ruleSet, {required bool rejectExpired}) async {
    final metadata = ruleSet.metadata;
    if (metadata.formatVersion != 1) {
      throw const RuleSetValidationException('unsupported format version');
    }
    if (metadata.domainCount != ruleSet.domainSuffixes.length || metadata.cidrCount != ruleSet.ipCidrs.length) {
      throw const RuleSetValidationException('entry count mismatch');
    }
    final checksum = await normalizer.checksumForPayload(ruleSet.payload);
    if (checksum != metadata.checksum.toLowerCase()) {
      throw const RuleSetValidationException('checksum mismatch');
    }
    if (rejectExpired && !metadata.expiresAt.isAfter(now().toUtc())) {
      throw const RuleSetValidationException('expired rule-set');
    }
  }

  String _path(String id) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]+$').hasMatch(id)) {
      throw const RuleSetValidationException('invalid rule-set id');
    }
    return '${directory.path}${Platform.pathSeparator}$id.json';
  }
}

class RuleConflict {
  const RuleConflict({required this.value, required this.winner, required this.loser, required this.reason});

  final String value;
  final ManagedRuleSet winner;
  final ManagedRuleSet loser;
  final String reason;
}

List<RuleConflict> detectRuleConflicts(Iterable<ManagedRuleSet> ruleSets) {
  final ordered = ruleSets.toList()..sort((left, right) => left.metadata.priority.compareTo(right.metadata.priority));
  final owners = <String, ManagedRuleSet>{};
  final conflicts = <RuleConflict>[];
  for (final ruleSet in ordered) {
    for (final value in [...ruleSet.domainSuffixes, ...ruleSet.ipCidrs]) {
      final existing = owners[value];
      if (existing == null) {
        owners[value] = ruleSet;
      } else if (existing.metadata.action != ruleSet.metadata.action) {
        conflicts.add(
          RuleConflict(value: value, winner: existing, loser: ruleSet, reason: 'lower numeric priority wins'),
        );
      }
    }
  }
  return conflicts;
}
