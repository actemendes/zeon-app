import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/profile/data/profile_parser.dart';

/// The five self-signed FREE Trojan servers can only be verified when the
/// generated profile keeps the `tls.certificate` trust anchor the canonical
/// sing-box subscription ships. The legacy representation the endpoint
/// serves to unrecognized clients carries only an Xray-style
/// `pinnedPeerCertSha256`, which the URI conversion cannot express and
/// therefore drops - which is what produced
/// `x509: certificate signed by unknown authority`.
void main() {
  const pem =
      '-----BEGIN CERTIFICATE-----\n'
      'MIIBmDCCAT6gAwIBAgIUYYQCb4rMY8wsgg4aW77Pu6UVjuowCgYIKoZIzj0EAwIw\n'
      '-----END CERTIFICATE-----\n';

  String singBoxSubscription() => jsonEncode({
    "log": {"level": "warn"},
    "outbounds": [
      {
        "type": "trojan",
        "tag": "🇸🇪Швеция2 | FREE 10 Мбит/с",
        "server": "41.216.182.242",
        "server_port": 443,
        "password": "secret",
        "tls": {
          "enabled": true,
          "server_name": "41.216.182.242",
          "alpn": ["h2", "http/1.1"],
          "utls": {"enabled": true, "fingerprint": "chrome"},
          "certificate": pem,
        },
      },
    ],
  });

  group('canonical sing-box subscription survives core-import normalization', () {
    test('tls.certificate is preserved verbatim', () {
      final normalized = ProfileParser.normalizeContentForCoreImport(singBoxSubscription());

      final decoded = jsonDecode(normalized) as Map<String, dynamic>;
      final outbound = (decoded["outbounds"] as List).single as Map<String, dynamic>;
      final tls = outbound["tls"] as Map<String, dynamic>;

      expect(tls["certificate"], pem);
      expect(tls["server_name"], "41.216.182.242");
      expect((tls["utls"] as Map)["fingerprint"], "chrome");
      expect(outbound["type"], "trojan");
    });

    test('sing-box outbounds are not rewritten into certificate-less URIs', () {
      final normalized = ProfileParser.normalizeContentForCoreImport(singBoxSubscription());

      expect(
        normalized.trimLeft().startsWith('{'),
        isTrue,
        reason: 'a native sing-box config must stay JSON; converting it to a '
            'trojan:// URI list would silently discard tls.certificate',
      );
      expect(normalized, contains('BEGIN CERTIFICATE'));
    });

    test('legacy Xray representation cannot carry the pin into a URI', () {
      // Documents the behaviour that made the bug invisible: the Xray form
      // parses fine and yields a working-looking profile, minus the trust
      // material. It must therefore never be the format we consume.
      final xrayLine = jsonEncode({
        "remarks": "🇸🇪Швеция2 | FREE 10 Мбит/с",
        "outbounds": [
          {
            "tag": "proxy",
            "protocol": "trojan",
            "settings": {
              "servers": [
                {"address": "41.216.182.242", "port": 443, "password": "secret"},
              ],
            },
            "streamSettings": {
              "security": "tls",
              "network": "tcp",
              "tlsSettings": {
                "serverName": "41.216.182.242",
                "fingerprint": "chrome",
                "pinnedPeerCertSha256":
                    "2fd80181c70c83dd1e4edf937d17209f11e1df715b6c471b3780af20a2992856",
              },
            },
          },
        ],
      });

      final normalized = ProfileParser.normalizeContentForCoreImport(xrayLine);

      expect(normalized, startsWith('trojan://'));
      expect(normalized, isNot(contains('pinnedPeerCertSha256')));
      expect(normalized, isNot(contains('BEGIN CERTIFICATE')));
    });
  });
}
