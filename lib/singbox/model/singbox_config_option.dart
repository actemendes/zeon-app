import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:zeon/core/model/optional_range.dart';
import 'package:zeon/core/utils/json_converters.dart';
import 'package:zeon/features/log/model/log_level.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/singbox/model/singbox_rule.dart';

part 'singbox_config_option.freezed.dart';
part 'singbox_config_option.g.dart';

@freezed
class SingboxConfigOption with _$SingboxConfigOption {
  const SingboxConfigOption._();

  @JsonSerializable(fieldRename: FieldRename.kebab)
  const factory SingboxConfigOption({
    required String region,
    required BalancerStrategy balancerStrategy,
    required bool blockAds,
    required bool useXrayCoreWhenPossible,
    required bool executeConfigAsIs,
    required LogLevel logLevel,
    required bool resolveDestination,
    required IPv6Mode ipv6Mode,
    required String remoteDnsAddress,
    required DomainStrategy remoteDnsDomainStrategy,
    required String directDnsAddress,
    required DomainStrategy directDnsDomainStrategy,
    required int mixedPort,
    required int tproxyPort,
    required int directPort,
    required int redirectPort,
    required TunImplementation tunImplementation,
    required int mtu,
    required bool strictRoute,
    required String networkProfile,
    required String networkMtuMode,
    required String fragmentMode,
    required String profileDnsStrategy,
    required String connectionTestUrl,
    @IntervalInSecondsConverter() required Duration urlTestInterval,
    required bool enableClashApi,
    required int clashApiPort,
    required bool enableTun,
    // required bool enableTunService,
    required bool setSystemProxy,
    required bool bypassLan,
    required bool allowConnectionFromLan,
    required bool enableFakeDns,
    // required bool enableDnsRouting,
    required bool independentDnsCache,
    required String siteRoutingMode,
    required List<String> siteRoutingInclude,
    required List<String> siteRoutingExclude,
    required List<SingboxRule> rules,
    // required SingboxMuxOption mux,
    required SingboxTlsTricks tlsTricks,
    required SingboxWarpOption warp,
    required SingboxWarpOption warp2,
  }) = _SingboxConfigOption;

  String format() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(toJson());
  }

  Map<String, dynamic> toCoreJson() {
    final map = Map<String, dynamic>.from(toJson());
    map.remove("site-routing-mode");
    map.remove("site-routing-include");
    map.remove("site-routing-exclude");
    // Canonical key is enable-full-config; keep execute-config-as-is as a legacy alias.
    map["enable-full-config"] = executeConfigAsIs;
    map["execute-config-as-is"] = executeConfigAsIs;
    map["rules"] = rules.map((rule) => rule.toCoreJson()).toList();
    if (kDebugMode) {
      _addSmartActiveDebugDefines(map);
    }
    return map;
  }

  static void _addSmartActiveDebugDefines(Map<String, dynamic> map) {
    const stringDefines = <String, String>{
      "smart_active_debug_force_status": String.fromEnvironment("SMART_ACTIVE_DEBUG_FORCE_STATUS"),
      "smart_active_debug_force_error": String.fromEnvironment("SMART_ACTIVE_DEBUG_FORCE_ERROR"),
      "smart_active_debug_force_candidate": String.fromEnvironment("SMART_ACTIVE_DEBUG_FORCE_CANDIDATE"),
    };
    for (final entry in stringDefines.entries) {
      if (entry.value.isNotEmpty) map[entry.key] = entry.value;
    }

    const intDefines = <String, String>{
      "smart_active_debug_force_degradation": String.fromEnvironment("SMART_ACTIVE_DEBUG_FORCE_DEGRADATION"),
      "smart_active_debug_runtime_penalty": String.fromEnvironment("SMART_ACTIVE_DEBUG_RUNTIME_PENALTY"),
      "smart_active_debug_real_user_penalty": String.fromEnvironment("SMART_ACTIVE_DEBUG_REAL_USER_PENALTY"),
      "smart_active_debug_candidate_score": String.fromEnvironment("SMART_ACTIVE_DEBUG_CANDIDATE_SCORE"),
    };
    for (final entry in intDefines.entries) {
      final value = int.tryParse(entry.value);
      if (value != null && value > 0) map[entry.key] = value;
    }
  }

  factory SingboxConfigOption.fromJson(Map<String, dynamic> json) => _$SingboxConfigOptionFromJson(json);
}

@freezed
class SingboxWarpOption with _$SingboxWarpOption {
  @JsonSerializable(fieldRename: FieldRename.kebab)
  const factory SingboxWarpOption({
    required bool enable,
    required WarpDetourMode mode,
    required String wireguardConfig,
    required String licenseKey,
    required String accountId,
    required String accessToken,
    required String cleanIp,
    required int cleanPort,
    @OptionalRangeJsonConverter() required OptionalRange noise,
    @OptionalRangeJsonConverter() required OptionalRange noiseSize,
    @OptionalRangeJsonConverter() required OptionalRange noiseDelay,
    @OptionalRangeJsonConverter() required String noiseMode,
  }) = _SingboxWarpOption;

  factory SingboxWarpOption.fromJson(Map<String, dynamic> json) => _$SingboxWarpOptionFromJson(json);
}

// @freezed
// class SingboxMuxOption with _$SingboxMuxOption {
//   @JsonSerializable(fieldRename: FieldRename.kebab)
//   const factory SingboxMuxOption({
//     required bool enable,
//     required bool padding,
//     required int maxStreams,
//     required MuxProtocol protocol,
//   }) = _SingboxMuxOption;

//   factory SingboxMuxOption.fromJson(Map<String, dynamic> json) => _$SingboxMuxOptionFromJson(json);
// }

@freezed
class SingboxTlsTricks with _$SingboxTlsTricks {
  @JsonSerializable(fieldRename: FieldRename.kebab)
  const factory SingboxTlsTricks({
    required bool enableFragment,
    @OptionalRangeJsonConverter() required OptionalRange fragmentSize,
    @OptionalRangeJsonConverter() required OptionalRange fragmentSleep,
    required bool mixedSniCase,
    required bool enablePadding,
    @OptionalRangeJsonConverter() required OptionalRange paddingSize,
  }) = _SingboxTlsTricks;

  factory SingboxTlsTricks.fromJson(Map<String, dynamic> json) => _$SingboxTlsTricksFromJson(json);
}
