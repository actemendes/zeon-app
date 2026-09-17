import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/gen/translations.g.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  setUpAll(() async {
    await AppLocale.ru.build();
  });
  test("formats balancer as auto selection", () {
    expect(
      formatProxyDisplayName("balance", autoSelectionLabel: AppLocale.ru.buildSync().pages.proxies.autoSelection),
      "\u0410\u0432\u0442\u043e\u0432\u044b\u0431\u043e\u0440",
    );
  });

  test("hides auto server configurations", () {
    expect(shouldHideProxyOption(tag: "proxy-1", tagDisplay: "\u0410\u0412\u0422\u041e | WI-FI"), isTrue);
    expect(shouldHideProxyOption(tag: "\u0410\u0412\u0422\u041e | MOBILE", tagDisplay: "proxy-2"), isTrue);
    expect(shouldHideProxyOption(tag: "proxy-3", tagDisplay: "Germany"), isFalse);
  });

  test("keeps flag source while hiding leading flag from server title", () {
    final outbound = OutboundInfo(tag: "proxy-1", tagDisplay: "\uD83C\uDDE9\uD83C\uDDEA Germany", type: "vless");

    final displayInfo = resolveOutboundDisplayInfo(
      outbound,
      autoSelectionLabel: AppLocale.en.buildSync().pages.proxies.autoSelection,
    );

    expect(displayInfo.countryCode, "DE");
    expect(displayInfo.title, "Germany");
    expect(outbound.tagDisplay, "\uD83C\uDDE9\uD83C\uDDEA Germany");
  });
}
