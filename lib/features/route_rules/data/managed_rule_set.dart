import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

enum ManagedRuleAction { direct, vpn, block }

enum ManagedRulePreset { russia, global, all }

enum ManagedRuleFormat { json, srs }

const managedRuleSetEnvelopeFormatVersion = 1;
const managedRuleSetMaxEnvelopeBytes = 4 << 20;
const managedRuleSetMaxRuleSets = 32;
const managedRuleSetMaxEntries = 100000;

final RegExp _managedRuleSetIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
final RegExp _sha256Pattern = RegExp(r'^[a-fA-F0-9]{64}$');

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
    this.format = ManagedRuleFormat.json,
    this.size = 0,
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
  final ManagedRuleFormat format;
  final int size;

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
    'format': format.name,
    'size': size,
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
      format: ManagedRuleFormat.values.byName((json['format'] as String?) ?? 'json'),
      size: (json['size'] as int?) ?? 0,
    );
  }
}

@immutable
class ManagedRuleSet {
  const ManagedRuleSet({required this.metadata, required this.domainSuffixes, required this.ipCidrs, this.srsBytes});

  final ManagedRuleSetMetadata metadata;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;
  final List<int>? srsBytes;

  Map<String, Object?> get payload => {
    'domainSuffix': domainSuffixes,
    'ipCidr': ipCidrs,
    if (srsBytes != null) 'srsBase64': base64.encode(srsBytes!),
  };

  Map<String, Object?> toJson() => {'metadata': metadata.toJson(), 'payload': payload};

  factory ManagedRuleSet.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'] as Map<String, dynamic>;
    final metadata = ManagedRuleSetMetadata.fromJson(json['metadata'] as Map<String, dynamic>);
    final rawSrs = payload['srsBase64'];
    return ManagedRuleSet(
      metadata: metadata,
      domainSuffixes: List<String>.unmodifiable((payload['domainSuffix'] as List).cast<String>()),
      ipCidrs: List<String>.unmodifiable((payload['ipCidr'] as List).cast<String>()),
      srsBytes: rawSrs == null ? null : List<int>.unmodifiable(base64.decode(rawSrs as String)),
    );
  }
}

@immutable
class ManagedRuleSetBundle {
  const ManagedRuleSetBundle({required this.generatedAt, required this.expiresAt, required this.ruleSets});

  final DateTime generatedAt;
  final DateTime expiresAt;
  final List<ManagedRuleSet> ruleSets;

  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'ruleSets': ruleSets.map((ruleSet) => ruleSet.toJson()).toList(growable: false),
  };

  factory ManagedRuleSetBundle.fromJson(Map<String, dynamic> json) {
    final rawRuleSets = json['ruleSets'];
    if (rawRuleSets is! List) {
      throw const RuleSetValidationException('ruleSets must be an array');
    }
    return ManagedRuleSetBundle(
      generatedAt: _requiredDateTime(json, 'generatedAt'),
      expiresAt: _requiredDateTime(json, 'expiresAt'),
      ruleSets: List<ManagedRuleSet>.unmodifiable(
        rawRuleSets.map((raw) {
          if (raw is! Map) {
            throw const RuleSetValidationException('rule-set must be an object');
          }
          return ManagedRuleSet.fromJson(Map<String, dynamic>.from(raw));
        }),
      ),
    );
  }
}

@immutable
class ManagedRuleSetEnvelope {
  const ManagedRuleSetEnvelope({
    required this.formatVersion,
    required this.generation,
    required this.payload,
    required this.checksum,
  });

  final int formatVersion;
  final int generation;
  final String payload;
  final String checksum;

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'generation': generation,
    'payload': payload,
    'checksum': checksum,
  };

  factory ManagedRuleSetEnvelope.fromJson(Map<String, dynamic> json) {
    final formatVersion = json['formatVersion'];
    final generation = json['generation'];
    final payload = json['payload'];
    final checksum = json['checksum'];
    if (formatVersion is! int || generation is! int || payload is! String || checksum is! String) {
      throw const RuleSetValidationException('invalid rule-set envelope schema');
    }
    return ManagedRuleSetEnvelope(
      formatVersion: formatVersion,
      generation: generation,
      payload: payload,
      checksum: checksum.toLowerCase(),
    );
  }
}

@immutable
class ManagedRuleSetSnapshot {
  const ManagedRuleSetSnapshot({required this.envelope, required this.bundle, required this.payloadBytes});

  final ManagedRuleSetEnvelope envelope;
  final ManagedRuleSetBundle bundle;
  final List<int> payloadBytes;
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

  File get activeFile => File('${directory.path}${Platform.pathSeparator}active.json');
  File get temporaryActiveFile => File('${activeFile.path}.tmp');
  File get lastKnownGoodActiveFile => File('${activeFile.path}.lkg');
  Directory get artifactDirectory => Directory('${directory.path}${Platform.pathSeparator}artifacts');

  File artifactFile(ManagedRuleSet ruleSet) =>
      File('${artifactDirectory.path}${Platform.pathSeparator}${ruleSet.metadata.id}-${ruleSet.metadata.checksum}.srs');

  Future<ManagedRuleSetSnapshot?> readActiveBundle() async {
    final active = await _tryReadEnvelopeFile(activeFile, rejectExpired: false);
    if (active != null) return active;

    final lastKnownGood = await _tryReadEnvelopeFile(lastKnownGoodActiveFile, rejectExpired: false);
    if (lastKnownGood != null) {
      await _restoreEnvelope(lastKnownGoodActiveFile);
      return lastKnownGood;
    }

    // A first installation can be interrupted after the fully validated
    // temporary file is flushed but before it is promoted. With no previous
    // bundle to recover, that verified temporary file is safe to finish.
    final temporary = await _tryReadEnvelopeFile(temporaryActiveFile, rejectExpired: false);
    if (temporary != null) {
      await _restoreEnvelope(temporaryActiveFile);
      return temporary;
    }
    return null;
  }

  Future<ManagedRuleSetSnapshot> validateEnvelope(
    ManagedRuleSetEnvelope envelope, {
    required bool rejectExpired,
  }) async {
    if (envelope.formatVersion != managedRuleSetEnvelopeFormatVersion || envelope.generation < 0) {
      throw const RuleSetValidationException('unsupported rule-set envelope');
    }
    if (!_sha256Pattern.hasMatch(envelope.checksum)) {
      throw const RuleSetValidationException('invalid envelope checksum');
    }

    final encodedEnvelope = utf8.encode(jsonEncode(envelope.toJson()));
    if (encodedEnvelope.isEmpty || encodedEnvelope.length > managedRuleSetMaxEnvelopeBytes) {
      throw const RuleSetValidationException('rule-set envelope is too large');
    }
    if (envelope.payload.isEmpty || envelope.payload.length > managedRuleSetMaxEnvelopeBytes) {
      throw const RuleSetValidationException('rule-set payload is too large');
    }

    final List<int> payloadBytes;
    try {
      payloadBytes = base64Url.decode(_withBase64Padding(envelope.payload));
    } on FormatException {
      throw const RuleSetValidationException('invalid base64url payload');
    }
    final payloadChecksum = await _sha256Hex(payloadBytes);
    if (payloadChecksum != envelope.checksum.toLowerCase()) {
      // The exact signed/encoded bytes are authenticated before JSON parsing.
      throw const RuleSetValidationException('envelope checksum mismatch');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(payloadBytes));
    } on Object {
      throw const RuleSetValidationException('invalid rule-set bundle payload');
    }
    if (decoded is! Map) {
      throw const RuleSetValidationException('rule-set bundle must be an object');
    }

    final ManagedRuleSetBundle bundle;
    try {
      bundle = ManagedRuleSetBundle.fromJson(Map<String, dynamic>.from(decoded));
    } on RuleSetValidationException {
      rethrow;
    } on Object {
      throw const RuleSetValidationException('invalid rule-set bundle schema');
    }
    await _verifyBundle(bundle, rejectExpired: rejectExpired);
    return ManagedRuleSetSnapshot(envelope: envelope, bundle: bundle, payloadBytes: List.unmodifiable(payloadBytes));
  }

  Future<ManagedRuleSetSnapshot> installEnvelope(ManagedRuleSetEnvelope candidate) async {
    final verified = await validateEnvelope(candidate, rejectExpired: true);
    final current = await readActiveBundle();
    if (current != null) {
      if (candidate.generation < current.envelope.generation) {
        throw const RuleSetValidationException('rule-set generation rollback');
      }
      if (candidate.generation == current.envelope.generation) {
        if (candidate.checksum != current.envelope.checksum) {
          throw const RuleSetValidationException('rule-set generation collision');
        }
        return current;
      }
    }

    await directory.create(recursive: true);
    await _ensureArtifacts(verified);
    final serialized = jsonEncode(candidate.toJson());
    await temporaryActiveFile.writeAsString(serialized, flush: true);
    await _decodeEnvelope(await temporaryActiveFile.readAsString(), rejectExpired: true);

    final validActive = await _tryReadEnvelopeFile(activeFile, rejectExpired: false);
    if (validActive != null) {
      final backupTemporary = File('${lastKnownGoodActiveFile.path}.tmp');
      await backupTemporary.writeAsBytes(await activeFile.readAsBytes(), flush: true);
      await _decodeEnvelope(await backupTemporary.readAsString(), rejectExpired: false);
      if (await lastKnownGoodActiveFile.exists()) await lastKnownGoodActiveFile.delete();
      await backupTemporary.rename(lastKnownGoodActiveFile.path);
    }

    try {
      await _promoteTemporaryActive();
    } on Object {
      await _recoverLastKnownGoodAfterFailedPromotion();
      rethrow;
    }
    return verified;
  }

  Future<ManagedRuleSet?> readLastKnownGood(String id) async {
    final file = File(_path(id));
    if (!await file.exists()) return null;
    return _decodeAndVerify(await file.readAsString(), rejectExpired: false);
  }

  Future<ManagedRuleSet> install(ManagedRuleSet candidate) async {
    await _verifyRuleSet(candidate, rejectExpired: true);
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
    await _verifyRuleSet(result, rejectExpired: rejectExpired);
    return result;
  }

  Future<void> _verifyBundle(ManagedRuleSetBundle bundle, {required bool rejectExpired}) async {
    if (!bundle.expiresAt.isAfter(bundle.generatedAt)) {
      throw const RuleSetValidationException('invalid bundle validity interval');
    }
    if (rejectExpired && !bundle.expiresAt.isAfter(now().toUtc())) {
      throw const RuleSetValidationException('expired rule-set bundle');
    }
    if (bundle.ruleSets.length > managedRuleSetMaxRuleSets) {
      throw const RuleSetValidationException('too many rule sets');
    }

    var entries = 0;
    final ids = <String>{};
    for (final ruleSet in bundle.ruleSets) {
      if (!ids.add(ruleSet.metadata.id)) {
        throw const RuleSetValidationException('duplicate rule-set id');
      }
      entries += ruleSet.domainSuffixes.length + ruleSet.ipCidrs.length;
      if (entries > managedRuleSetMaxEntries) {
        throw const RuleSetValidationException('too many rule-set entries');
      }
      await _verifyRuleSet(ruleSet, rejectExpired: rejectExpired);
    }
    if (detectRuleConflicts(bundle.ruleSets).isNotEmpty) {
      throw const RuleSetValidationException('conflicting rule-set actions');
    }
  }

  Future<void> _verifyRuleSet(ManagedRuleSet ruleSet, {required bool rejectExpired}) async {
    final metadata = ruleSet.metadata;
    if (!_managedRuleSetIdPattern.hasMatch(metadata.id)) {
      throw const RuleSetValidationException('invalid rule-set id');
    }
    if (metadata.version.isEmpty || metadata.version.length > 128) {
      throw const RuleSetValidationException('invalid rule-set version');
    }
    if (metadata.source.isEmpty || metadata.source.length > 2048) {
      throw const RuleSetValidationException('invalid rule-set source');
    }
    if (metadata.formatVersion != 1) {
      throw const RuleSetValidationException('unsupported format version');
    }
    if (metadata.applicablePreset != ManagedRulePreset.russia && metadata.applicablePreset != ManagedRulePreset.all) {
      throw const RuleSetValidationException('unsupported rule-set preset');
    }
    if (!metadata.expiresAt.isAfter(metadata.generatedAt)) {
      throw const RuleSetValidationException('invalid rule-set validity interval');
    }
    if (metadata.domainCount < 0 || metadata.cidrCount < 0 || metadata.size < 0) {
      throw const RuleSetValidationException('invalid entry count');
    }
    if (metadata.domainCount != ruleSet.domainSuffixes.length || metadata.cidrCount != ruleSet.ipCidrs.length) {
      throw const RuleSetValidationException('entry count mismatch');
    }
    if (ruleSet.domainSuffixes.toSet().length != ruleSet.domainSuffixes.length ||
        ruleSet.ipCidrs.toSet().length != ruleSet.ipCidrs.length) {
      throw const RuleSetValidationException('duplicate rule-set entry');
    }
    for (final domain in ruleSet.domainSuffixes) {
      if (normalizer.normalizeDomain(domain) != domain) {
        throw const RuleSetValidationException('non-canonical domain suffix');
      }
    }
    for (final cidr in ruleSet.ipCidrs) {
      if (normalizer.normalizeCidr(cidr) != cidr) {
        throw const RuleSetValidationException('non-canonical CIDR');
      }
    }
    if (!_sha256Pattern.hasMatch(metadata.checksum)) {
      throw const RuleSetValidationException('invalid rule-set checksum');
    }
    if (metadata.format == ManagedRuleFormat.srs) {
      if (metadata.id != 'ads' ||
          metadata.action != ManagedRuleAction.block ||
          metadata.applicablePreset != ManagedRulePreset.all ||
          ruleSet.domainSuffixes.isNotEmpty ||
          ruleSet.ipCidrs.isNotEmpty ||
          ruleSet.srsBytes == null) {
        throw const RuleSetValidationException('invalid managed ads rule set');
      }
      _validateSrs(ruleSet.srsBytes!);
      if (metadata.size != ruleSet.srsBytes!.length || await _sha256Hex(ruleSet.srsBytes!) != metadata.checksum) {
        throw const RuleSetValidationException('SRS checksum or size mismatch');
      }
    } else if (ruleSet.srsBytes != null) {
      throw const RuleSetValidationException('unexpected SRS artifact');
    } else {
      final checksum = await normalizer.checksumForPayload(ruleSet.payload);
      if (checksum != metadata.checksum.toLowerCase()) {
        throw const RuleSetValidationException('checksum mismatch');
      }
    }
    if (rejectExpired && !metadata.expiresAt.isAfter(now().toUtc())) {
      throw const RuleSetValidationException('expired rule-set');
    }
  }

  Future<ManagedRuleSetSnapshot> _decodeEnvelope(String raw, {required bool rejectExpired}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object {
      throw const RuleSetValidationException('invalid rule-set envelope JSON');
    }
    if (decoded is! Map) {
      throw const RuleSetValidationException('rule-set envelope must be an object');
    }
    final envelope = ManagedRuleSetEnvelope.fromJson(Map<String, dynamic>.from(decoded));
    return validateEnvelope(envelope, rejectExpired: rejectExpired);
  }

  Future<ManagedRuleSetSnapshot?> _tryReadEnvelopeFile(File file, {required bool rejectExpired}) async {
    try {
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > managedRuleSetMaxEnvelopeBytes) return null;
      final snapshot = await _decodeEnvelope(await file.readAsString(), rejectExpired: rejectExpired);
      await _ensureArtifacts(snapshot);
      return snapshot;
    } on Object {
      return null;
    }
  }

  Future<void> _ensureArtifacts(ManagedRuleSetSnapshot snapshot) async {
    for (final ruleSet in snapshot.bundle.ruleSets.where((item) => item.metadata.format == ManagedRuleFormat.srs)) {
      final bytes = ruleSet.srsBytes!;
      final target = artifactFile(ruleSet);
      if (await target.exists()) {
        try {
          final existing = await target.readAsBytes();
          _validateSrs(existing);
          if (existing.length == bytes.length && await _sha256Hex(existing) == ruleSet.metadata.checksum) continue;
        } on Object {
          // The authenticated envelope below rematerializes the damaged artifact.
        }
      }
      await artifactDirectory.create(recursive: true);
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      _validateSrs(await temporary.readAsBytes());
      if (await _sha256Hex(await temporary.readAsBytes()) != ruleSet.metadata.checksum) {
        throw const RuleSetValidationException('materialized SRS checksum mismatch');
      }
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    }
  }

  Future<void> _promoteTemporaryActive() async {
    try {
      await temporaryActiveFile.rename(activeFile.path);
      return;
    } on FileSystemException {
      // Windows cannot atomically replace an existing destination. The
      // already-flushed .lkg file makes this short swap recoverable.
      if (await activeFile.exists()) await activeFile.delete();
      await temporaryActiveFile.rename(activeFile.path);
    }
  }

  Future<void> _recoverLastKnownGoodAfterFailedPromotion() async {
    if (await activeFile.exists()) return;
    if (await lastKnownGoodActiveFile.exists()) {
      await _restoreEnvelope(lastKnownGoodActiveFile);
    }
  }

  Future<void> _restoreEnvelope(File source) async {
    await directory.create(recursive: true);
    final recovery = File('${activeFile.path}.recover');
    await recovery.writeAsBytes(await source.readAsBytes(), flush: true);
    await _decodeEnvelope(await recovery.readAsString(), rejectExpired: false);
    if (await activeFile.exists()) await activeFile.delete();
    await recovery.rename(activeFile.path);
  }

  String _path(String id) {
    if (!_managedRuleSetIdPattern.hasMatch(id)) {
      throw const RuleSetValidationException('invalid rule-set id');
    }
    return '${directory.path}${Platform.pathSeparator}$id.json';
  }
}

DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final raw = json[key];
  if (raw is! String || raw.trim().isEmpty) {
    throw RuleSetValidationException('$key must be a timestamp');
  }
  final value = DateTime.tryParse(raw);
  if (value == null) throw RuleSetValidationException('$key must be a timestamp');
  return value.toUtc();
}

String _withBase64Padding(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(value)) {
    throw const RuleSetValidationException('invalid base64url payload');
  }
  final unpadded = value.replaceFirst(RegExp(r'=+$'), '');
  return unpadded.padRight(unpadded.length + ((4 - unpadded.length % 4) % 4), '=');
}

Future<String> _sha256Hex(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

void _validateSrs(List<int> bytes) {
  if (bytes.length < 6 || bytes[0] != 0x53 || bytes[1] != 0x52 || bytes[2] != 0x53 || bytes[3] > 4) {
    throw const RuleSetValidationException('invalid SRS header or version');
  }
  final List<int> inflated;
  try {
    inflated = ZLibDecoder().convert(bytes.sublist(4));
  } on Object {
    throw const RuleSetValidationException('corrupted SRS artifact');
  }
  var count = 0;
  var shift = 0;
  var complete = false;
  for (final byte in inflated.take(10)) {
    count |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) {
      complete = true;
      break;
    }
    shift += 7;
  }
  if (!complete || count <= 0 || inflated.length < 2) {
    throw const RuleSetValidationException('SRS artifact contains no readable rules');
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
