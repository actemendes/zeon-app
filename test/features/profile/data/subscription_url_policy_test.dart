import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/profile/data/subscription_url_policy.dart';

void main() {
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
