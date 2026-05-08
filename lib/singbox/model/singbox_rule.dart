import 'package:freezed_annotation/freezed_annotation.dart';

part 'singbox_rule.freezed.dart';
part 'singbox_rule.g.dart';

@freezed
class SingboxRule with _$SingboxRule {
  const SingboxRule._();

  @JsonSerializable(fieldRename: FieldRename.kebab)
  const factory SingboxRule({
    String? ruleSetUrl,
    @Default(<String>[]) List<String> domains,
    String? ip,
    String? port,
    String? protocol,
    @Default(RuleNetwork.tcpAndUdp) RuleNetwork network,
    @Default(RuleOutbound.proxy) RuleOutbound outbound,
  }) = _SingboxRule;

  factory SingboxRule.fromJson(Map<String, dynamic> json) => _$SingboxRuleFromJson(json);

  /// Serializes rule in the shape expected by hiddify-core `config.Rule`.
  Map<String, dynamic> toCoreJson() {
    final map = <String, dynamic>{
      // Route builder skips rules with enabled=false by default.
      "enabled": true,
      "outbound": outbound.toCoreValue(),
    };

    if (domains.isNotEmpty) {
      map["domains"] = List<String>.from(domains);
    }

    final ruleSet = ruleSetUrl?.trim();
    if (ruleSet != null && ruleSet.isNotEmpty) {
      map["rule_sets"] = <String>[ruleSet];
    }

    final ipCidrs = _splitCsv(ip);
    if (ipCidrs.isNotEmpty) {
      map["ip_cidrs"] = ipCidrs;
    }

    final portRanges = _splitCsv(port);
    if (portRanges.isNotEmpty) {
      map["port_ranges"] = portRanges;
    }

    final networkValue = network.toCoreValue();
    if (networkValue != null) {
      map["network"] = networkValue;
    }

    final protocols = _parseProtocols(protocol);
    if (protocols.isNotEmpty) {
      map["protocols"] = protocols;
    }

    return map;
  }

  static List<String> _splitCsv(String? value) {
    if (value == null) return const <String>[];
    return value.split(",").map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
  }

  static List<int> _parseProtocols(String? value) {
    if (value == null || value.trim().isEmpty) return const <int>[];
    const protocolMap = <String, int>{"tls": 0, "http": 1, "quic": 2, "stun": 3, "dns": 4, "bittorrent": 5};
    final result = <int>[];
    for (final item in value.split(",")) {
      final key = item.trim().toLowerCase();
      final protocol = protocolMap[key];
      if (protocol != null) {
        result.add(protocol);
      }
    }
    return result;
  }
}

enum RuleOutbound { proxy, bypass, block }

extension RuleOutboundCore on RuleOutbound {
  int toCoreValue() => switch (this) {
    RuleOutbound.proxy => 0,
    RuleOutbound.bypass => 1,
    RuleOutbound.block => 3,
  };
}

@JsonEnum(valueField: 'key')
enum RuleNetwork {
  tcpAndUdp(""),
  tcp("tcp"),
  udp("udp");

  const RuleNetwork(this.key);

  final String? key;
}

extension RuleNetworkCore on RuleNetwork {
  /// Returns null for "all" to use core default enum value.
  int? toCoreValue() => switch (this) {
    RuleNetwork.tcpAndUdp => null,
    RuleNetwork.tcp => 1,
    RuleNetwork.udp => 2,
  };
}
