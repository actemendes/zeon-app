import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';

void main() {
  test("formats balancer as auto selection", () {
    expect(formatProxyDisplayName("balance"), "\u0410\u0432\u0442\u043e\u0432\u044b\u0431\u043e\u0440");
  });

  test("hides auto server configurations", () {
    expect(shouldHideProxyOption(tag: "proxy-1", tagDisplay: "\u0410\u0412\u0422\u041e | WI-FI"), isTrue);
    expect(shouldHideProxyOption(tag: "\u0410\u0412\u0422\u041e | MOBILE", tagDisplay: "proxy-2"), isTrue);
    expect(shouldHideProxyOption(tag: "proxy-3", tagDisplay: "Germany"), isFalse);
  });
}
