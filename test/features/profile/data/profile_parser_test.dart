import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/profile/data/profile_parser.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:uuid/uuid.dart';

void main() {
  const validBaseUrl = "https://example.com/configurations/user1/filename.yaml";
  const validExtendedUrl = "https://example.com/configurations/user1/filename.yaml?test#b";
  const validSupportUrl = "https://example.com/support";

  group("publicFallbackUrl", () {
    test("maps canonical open links to the public TUN-accessible endpoint", () {
      expect(
        ProfileParser.publicFallbackUrl("https://130.49.151.173/open/8288649125"),
        "https://zeon-vps.link/open/8288649125",
      );
    });

    test("maps canonical subscription links to the public Netlify endpoint", () {
      expect(
        ProfileParser.publicFallbackUrl("https://130.49.151.173/subscription/3435bc25-d3db-4d2b-a6ed-84703bc97880"),
        "https://ok24-server.com/.netlify/functions/subscription/3435bc25-d3db-4d2b-a6ed-84703bc97880",
      );
    });

    test("does not rewrite unrelated profile links", () {
      expect(ProfileParser.publicFallbackUrl(validBaseUrl), isNull);
    });
  });

  group("parse", () {
    test("Should use filename in url with no headers and fragment", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validBaseUrl,
          lastUpdate: DateTime.now(),
        ),
      );
      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        expect(r is RemoteProfileEntity, true);
        r.map(
          remote: (rp) {
            expect(rp.name, equals("filename"));
            expect(rp.url, equals(validBaseUrl));
            expect(rp.options, isNull);
            expect(rp.subInfo, isNull);
          },
          local: (lp) {},
        );
      });
    });

    test("Should use fragment in url with no headers", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validExtendedUrl,
          lastUpdate: DateTime.now(),
        ),
      );
      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        expect(r is RemoteProfileEntity, true);
        r.map(
          remote: (rp) {
            expect(rp.name, equals("b"));
            expect(rp.url, equals(validExtendedUrl));
            expect(rp.options, isNull);
            expect(rp.subInfo, isNull);
          },
          local: (lp) {},
        );
      });
    });

    test("Should use base64 title in headers", () {
      final headers = <String, List<String>>{
        "profile-title": ["base64:ZXhhbXBsZVRpdGxl"],
        "profile-update-interval": ["1"],
        "connection-test-url": [validBaseUrl],
        "remote-dns-address": [validBaseUrl],
        "subscription-userinfo": ["upload=0;download=1024;total=10240.5;expire=1704054600.55"],
        "profile-web-page-url": [validBaseUrl],
        "support-url": [validSupportUrl],
      };
      // This fix occurs in the _downloadProfile method within ProfileParser, and the fixed headers are passed to populateHeaders
      final fixedHeaders = headers.map((key, value) {
        if (value.length == 1) return MapEntry(key, value.first);
        return MapEntry(key, value);
      });
      final allHeaders = ProfileParser.populateHeaders(content: '', remoteHeaders: fixedHeaders);
      expect(allHeaders.isRight(), true);
      allHeaders.match((l) {}, (r) {
        final profile = ProfileParser.parse(
          tempFilePath: '',
          profile: ProfileEntity.remote(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validExtendedUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: r,
          ),
        );
        expect(profile.isRight(), true);
        profile.match((l) {}, (r) {
          expect(r is RemoteProfileEntity, true);
          r.map(
            remote: (rp) {
              expect(rp.name, equals("exampleTitle"));
              expect(rp.url, equals(validExtendedUrl));
              expect(rp.options, equals(const ProfileOptions(updateInterval: Duration(hours: 1))));
              expect(
                rp.subInfo,
                equals(
                  SubscriptionInfo(
                    upload: 0,
                    download: 1024,
                    total: 10240,
                    expire: DateTime.fromMillisecondsSinceEpoch(1704054600 * 1000),
                    webPageUrl: validBaseUrl,
                    supportUrl: validSupportUrl,
                  ),
                ),
              );
            },
            local: (lp) {},
          );
        });
      });
    });

    test("Should use infinite when given 0 for subscription properties", () {
      final headers = <String, List<String>>{
        "profile-title": ["title"],
        "profile-update-interval": ["1"],
        "subscription-userinfo": ["upload=0;download=1024;total=0;expire=0"],
        "profile-web-page-url": [validBaseUrl],
        "support-url": [validSupportUrl],
      };
      // This fix occurs in the _downloadProfile method within ProfileParser, and the fixed headers are passed to populateHeaders
      final fixedHeaders = headers.map((key, value) {
        if (value.length == 1) return MapEntry(key, value.first);
        return MapEntry(key, value);
      });
      final allHeaders = ProfileParser.populateHeaders(content: '', remoteHeaders: fixedHeaders);
      expect(allHeaders.isRight(), true);
      allHeaders.match((l) {}, (r) {
        final profile = ProfileParser.parse(
          tempFilePath: '',
          profile: RemoteProfileEntity(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validBaseUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: r,
          ),
        );
        expect(profile.isRight(), true);
        profile.match((l) {}, (r) {
          expect(r is RemoteProfileEntity, true);
          r.map(
            remote: (rp) {
              expect(rp.subInfo, isNotNull);
              expect(rp.subInfo!.total, equals(ProfileParser.infiniteTrafficThreshold + 1));
              expect(
                rp.subInfo!.expire,
                equals(DateTime.fromMillisecondsSinceEpoch(ProfileParser.infiniteTimeThreshold * 1000)),
              );
            },
            local: (lp) {},
          );
        });
      });
    });

    test("Should normalize profile title with provider prefix", () {
      final headers = <String, dynamic>{"profile-title": "ZEON | happy_fox_153"};
      final allHeaders = ProfileParser.populateHeaders(content: '', remoteHeaders: headers);
      expect(allHeaders.isRight(), true);

      allHeaders.match((l) {}, (r) {
        final profile = ProfileParser.parse(
          tempFilePath: '',
          profile: RemoteProfileEntity(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validBaseUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: r,
          ),
        );
        expect(profile.isRight(), true);
        profile.match((l) {}, (value) {
          value.map(remote: (rp) => expect(rp.name, equals("happy fox 153")), local: (lp) {});
        });
      });
    });
  });

  group("sanitizeImportedServerConfigs", () {
    test("removes auto server URI entries", () {
      final content = [
        "vless://id@example.com:443#%F0%9F%94%84%20%D0%90%D0%92%D0%A2%D0%9E%20%7C%20WI-FI",
        "vless://id@example.com:443#Germany",
      ].join("\n");

      expect(ProfileParser.sanitizeImportedServerConfigs(content), "vless://id@example.com:443#Germany");
    });

    test("removes emoji from URI server names", () {
      final content = [
        "vless://id@example.com:443#%F0%9F%87%A9%F0%9F%87%AA%20Germany",
        "trojan://pass@example.com:443#%E2%9A%A1%20Fast%20Server",
      ].join("\n");

      expect(
        ProfileParser.sanitizeImportedServerConfigs(content),
        ["vless://id@example.com:443#Germany", "trojan://pass@example.com:443#Fast%20Server"].join("\n"),
      );
    });

    test("removes emoji from JSON server names and selector references", () {
      const content = '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["\uD83C\uDDE9\uD83C\uDDEA Germany", "\u26A1 Fast"],
      "default": "\uD83C\uDDE9\uD83C\uDDEA Germany"
    },
    {"type": "vless", "tag": "\uD83C\uDDE9\uD83C\uDDEA Germany"},
    {"type": "trojan", "tag": "\u26A1 Fast"}
  ]
}
''';

      final sanitized = ProfileParser.sanitizeImportedServerConfigs(content);

      expect(sanitized, isNot(contains("\u{1F1E9}\u{1F1EA}")));
      expect(sanitized, isNot(contains("\u{26A1}")));
      expect(sanitized, contains('"tag":"Germany"'));
      expect(sanitized, contains('"default":"Germany"'));
      expect(sanitized, contains('"outbounds":["Germany","Fast"]'));
    });

    test("removes auto outbounds and selector references from JSON", () {
      const content = '''
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["\u0410\u0412\u0422\u041e | WI-FI", "Germany"],
      "default": "\u0410\u0412\u0422\u041e | WI-FI"
    },
    {"type": "vless", "tag": "\u0410\u0412\u0422\u041e | WI-FI"},
    {"type": "vless", "tag": "Germany"}
  ]
}
''';

      final sanitized = ProfileParser.sanitizeImportedServerConfigs(content);

      expect(sanitized, isNot(contains("\u0410\u0412\u0422\u041e |")));
      expect(sanitized, contains("Germany"));
      expect(sanitized, isNot(contains('"default"')));
    });
  });
}
