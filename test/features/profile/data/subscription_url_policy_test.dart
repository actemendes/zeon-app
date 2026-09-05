import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/profile/data/subscription_url_policy.dart';

void main() {
  group("canonicalizeZeonProfileUrl", () {
    test("migrates only the exact legacy IPv4 host", () {
      expect(
        canonicalizeZeonProfileUrl("https://130.49.151.173/subscription"),
        "https://api.zeon-vps.online/subscription",
      );
    });

    test("preserves path and query", () {
      expect(
        canonicalizeZeonProfileUrl("https://130.49.151.173/api/profile?id=123&x=abc"),
        "https://api.zeon-vps.online/api/profile?id=123&x=abc",
      );
    });

    test("preserves fragment", () {
      expect(
        canonicalizeZeonProfileUrl("https://130.49.151.173/a/b#selected"),
        "https://api.zeon-vps.online/a/b#selected",
      );
    });

    test("preserves HTTPS and an explicit port", () {
      expect(canonicalizeZeonProfileUrl("https://130.49.151.173:8443/a"), "https://api.zeon-vps.online:8443/a");
    });

    test("leaves the canonical domain unchanged", () {
      const source = "https://api.zeon-vps.online/subscription";
      expect(canonicalizeZeonProfileUrl(source), source);
    });

    test("leaves an unrelated IPv4 host unchanged", () {
      const source = "https://1.2.3.4/sub";
      expect(canonicalizeZeonProfileUrl(source), source);
    });

    test("leaves a nearby IPv4 host unchanged", () {
      const source = "https://130.49.151.174/sub";
      expect(canonicalizeZeonProfileUrl(source), source);
    });

    test("leaves an unrelated domain unchanged", () {
      const source = "https://example.com/sub";
      expect(canonicalizeZeonProfileUrl(source), source);
    });

    test("does not match a textual hostname suffix", () {
      const source = "https://130.49.151.173.example.com/sub";
      expect(canonicalizeZeonProfileUrl(source), source);
    });

    test("returns trimmed invalid input without throwing", () {
      expect(canonicalizeZeonProfileUrl("  not a URL  "), "not a URL");
    });
  });

  test("OK24 subscription URL explicitly requests ZEON sing-box format", () {
    final result = enforceZeonSingBoxSubscriptionUrl(
      "https://example.com/.netlify/functions/subscription/fixture-id?platform=android&format=xray",
    );
    final uri = Uri.parse(result);

    expect(uri.queryParameters["platform"], "android");
    expect(uri.queryParameters["format"], "sing-box");
    expect(uri.queryParameters["client"], "zeon");
  });

  test("third-party subscription URL is not modified", () {
    const source = "https://provider.example/subscription/fixture-id?format=clash";
    expect(enforceZeonSingBoxSubscriptionUrl(source), source);
  });
}
