import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/model/proxy_display_name.dart';

void main() {
  test("hides auto server configurations", () {
    expect(shouldHideProxyOption(tag: "proxy-1", tagDisplay: "\u0410\u0412\u0422\u041e | WI-FI"), isTrue);
    expect(shouldHideProxyOption(tag: "\u0410\u0412\u0422\u041e | MOBILE", tagDisplay: "proxy-2"), isTrue);
    expect(shouldHideProxyOption(tag: "proxy-3", tagDisplay: "Germany"), isFalse);
  });

  test("detects auto selection balance option", () {
    expect(isAutoSelectionProxyOption(tag: "balance", tagDisplay: "balance"), isTrue);
    expect(isAutoSelectionProxyOption(tag: "balance", tagDisplay: ""), isTrue);
    expect(isAutoSelectionProxyOption(tag: "proxy-1", tagDisplay: "Germany"), isFalse);
  });
}
