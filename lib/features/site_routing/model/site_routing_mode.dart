import 'package:zeon/core/localization/translations.dart';

enum SiteRoutingMode {
  off,
  include,
  exclude;

  bool get enabled => this != off;

  static SiteRoutingMode fromName(String? value) {
    if (value == null || value.isEmpty) return SiteRoutingMode.off;
    for (final mode in SiteRoutingMode.values) {
      if (mode.name == value) return mode;
    }
    return SiteRoutingMode.off;
  }

  ({String title, String message}) present(TranslationsEn t) => switch (this) {
    off => (
      title: t.pages.settings.routing.websites.modes.all,
      message: t.pages.settings.routing.websites.modes.allMsg,
    ),
    include => (
      title: t.pages.settings.routing.websites.modes.proxy,
      message: t.pages.settings.routing.websites.modes.proxyMsg,
    ),
    exclude => (
      title: t.pages.settings.routing.websites.modes.bypass,
      message: t.pages.settings.routing.websites.modes.bypassMsg,
    ),
  };
}
