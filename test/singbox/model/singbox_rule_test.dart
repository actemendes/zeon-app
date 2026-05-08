import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/singbox/model/singbox_rule.dart';

void main() {
  group("SingboxRule.toCoreJson", () {
    test("serializes include-site rule to core-safe payload", () {
      const rule = SingboxRule(domains: ["example.com"]);

      final json = rule.toCoreJson();

      expect(json["enabled"], isTrue);
      expect(json["outbound"], equals(0));
      expect(json["domains"], equals(const ["example.com"]));
      expect(json.containsKey("network"), isFalse);
    });

    test("serializes optional fields and enum mappings", () {
      const rule = SingboxRule(
        ruleSetUrl: "https://example.com/rules.srs",
        domains: ["example.org"],
        ip: "1.1.1.1/32, 8.8.8.0/24",
        port: "80,443",
        protocol: "tls,dns",
        network: RuleNetwork.udp,
        outbound: RuleOutbound.bypass,
      );

      final json = rule.toCoreJson();

      expect(json["enabled"], isTrue);
      expect(json["outbound"], equals(1));
      expect(json["rule_sets"], equals(const ["https://example.com/rules.srs"]));
      expect(json["ip_cidrs"], equals(const ["1.1.1.1/32", "8.8.8.0/24"]));
      expect(json["port_ranges"], equals(const ["80", "443"]));
      expect(json["protocols"], equals(const [0, 4]));
      expect(json["network"], equals(2));
    });
  });
}
