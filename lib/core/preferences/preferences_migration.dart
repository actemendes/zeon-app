import 'package:hiddify/utils/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PreferencesMigration with InfraLogger {
  PreferencesMigration({required this.sharedPreferences});

  final SharedPreferences sharedPreferences;

  static const versionKey = "preferences_version";

  Future<void> migrate() async {
    final currentVersion = sharedPreferences.getInt(versionKey) ?? 0;

    final List<PreferencesMigrationStep> migrationSteps = [
      PreferencesVersion1Migration(sharedPreferences),
      PreferencesVersion2Migration(sharedPreferences),
      PreferencesVersion3Migration(sharedPreferences),
      PreferencesVersion4Migration(sharedPreferences),
      PreferencesVersion5Migration(sharedPreferences),
      PreferencesVersion6Migration(sharedPreferences),
      PreferencesVersion7Migration(sharedPreferences),
    ];

    if (currentVersion == migrationSteps.length) {
      loggy.debug("already using the latest version (v$currentVersion)");
      return;
    }

    final stopWatch = Stopwatch()..start();
    loggy.debug("migrating from v[$currentVersion] to v[${migrationSteps.length}]");
    for (int i = currentVersion; i < migrationSteps.length; i++) {
      loggy.debug("step [$i](v${i + 1})");
      await migrationSteps[i].migrate();
      await sharedPreferences.setInt(versionKey, i + 1);
    }
    stopWatch.stop();
    loggy.debug("migration took [${stopWatch.elapsedMilliseconds}]ms");
  }
}

abstract interface class PreferencesMigrationStep {
  PreferencesMigrationStep(this.sharedPreferences);

  final SharedPreferences sharedPreferences;

  Future<void> migrate();
}

class PreferencesVersion1Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion1Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (sharedPreferences.getString("service-mode") case final String serviceMode) {
      final newMode = switch (serviceMode) {
        "proxy" || "system-proxy" || "vpn" => serviceMode,
        "systemProxy" => "system-proxy",
        "tun" => "vpn",
        _ => PlatformUtils.isDesktop ? "system-proxy" : "vpn",
      };
      loggy.debug("changing service-mode from [$serviceMode] to [$newMode]");
      await sharedPreferences.setString("service-mode", newMode);
    }

    if (sharedPreferences.getString("ipv6-mode") case final String ipv6Mode) {
      loggy.debug("changing ipv6-mode from [$ipv6Mode] to [${_ipv6Mapper(ipv6Mode)}]");
      await sharedPreferences.setString("ipv6-mode", _ipv6Mapper(ipv6Mode));
    }

    if (sharedPreferences.getString("remote-domain-dns-strategy") case final String remoteDomainStrategy) {
      loggy.debug(
        "changing [remote-domain-dns-strategy] = [$remoteDomainStrategy] to [remote-dns-domain-strategy] = [${_domainStrategyMapper(remoteDomainStrategy)}]",
      );
      await sharedPreferences.remove("remote-domain-dns-strategy");
      await sharedPreferences.setString("remote-dns-domain-strategy", _domainStrategyMapper(remoteDomainStrategy));
    }

    if (sharedPreferences.getString("direct-domain-dns-strategy") case final String directDomainStrategy) {
      loggy.debug(
        "changing [direct-domain-dns-strategy] = [$directDomainStrategy] to [direct-dns-domain-strategy] = [${_domainStrategyMapper(directDomainStrategy)}]",
      );
      await sharedPreferences.remove("direct-domain-dns-strategy");
      await sharedPreferences.setString("direct-dns-domain-strategy", _domainStrategyMapper(directDomainStrategy));
    }

    if (sharedPreferences.getInt("localDns-port") case final int directPort) {
      loggy.debug("changing [localDns-port] to [direct-port]");
      await sharedPreferences.remove("localDns-port");
      await sharedPreferences.setInt("direct-port", directPort);
    }

    await sharedPreferences.remove("execute-config-as-is");
    await sharedPreferences.remove("enable-tun");
    await sharedPreferences.remove("set-system-proxy");

    await sharedPreferences.remove("cron_profiles_update");
  }

  String _ipv6Mapper(String persisted) => switch (persisted) {
    "ipv4_only" || "prefer_ipv4" || "prefer_ipv4" || "ipv6_only" => persisted,
    "disable" => "ipv4_only",
    "enable" => "prefer_ipv4",
    "prefer" => "prefer_ipv6",
    "only" => "ipv6_only",
    _ => "ipv4_only",
  };

  String _domainStrategyMapper(String persisted) => switch (persisted) {
    "ipv4_only" || "prefer_ipv4" || "prefer_ipv4" || "ipv6_only" => persisted,
    "auto" => "",
    "preferIpv6" => "prefer_ipv6",
    "preferIpv4" => "prefer_ipv4",
    "ipv4Only" => "ipv4_only",
    "ipv6Only" => "ipv6_only",
    _ => "",
  };
}

class PreferencesVersion2Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion2Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    final region = sharedPreferences.getString("region");
    if (region != "ru") {
      return;
    }

    final directDns = sharedPreferences.getString("direct-dns-address");
    const externalDnsValues = {
      "1.1.1.1",
      "udp://1.1.1.1",
      "tcp://1.1.1.1",
      "https://1.1.1.1/dns-query",
      "https://dns.cloudflare.com/dns-query",
      "8.8.8.8",
      "udp://8.8.8.8",
      "tcp://8.8.8.8",
      "https://8.8.8.8/dns-query",
    };
    if (directDns == null || externalDnsValues.contains(directDns)) {
      loggy.debug("RU migration: changing direct-dns-address from [$directDns] to [local]");
      await sharedPreferences.setString("direct-dns-address", "local");
    }

    final strictRoute = sharedPreferences.getBool("strict-route");
    if (strictRoute == null || strictRoute == true) {
      loggy.debug("RU migration: changing strict-route from [$strictRoute] to [false]");
      await sharedPreferences.setBool("strict-route", false);
    }
  }
}

class PreferencesVersion3Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion3Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    final persistedMtu = sharedPreferences.getInt("mtu");
    if (persistedMtu == null || persistedMtu <= 0 || persistedMtu > 2000) {
      loggy.debug("stability migration: changing mtu from [$persistedMtu] to [1400]");
      await sharedPreferences.setInt("mtu", 1400);
    }

    final persistedStrategy = sharedPreferences.getString("balancer-strategy");
    if (persistedStrategy == null || persistedStrategy == "round-robin") {
      loggy.debug("stability migration: changing balancer-strategy from [$persistedStrategy] to [sticky-sessions]");
      await sharedPreferences.setString("balancer-strategy", "sticky-sessions");
    }

    final persistedTunImpl = sharedPreferences.getString("tun-implementation");
    if (persistedTunImpl == null || persistedTunImpl == "gvisor") {
      loggy.debug("stability migration: changing tun-implementation from [$persistedTunImpl] to [mixed]");
      await sharedPreferences.setString("tun-implementation", "mixed");
    }

    final strictRoute = sharedPreferences.getBool("strict-route");
    if (strictRoute == null || strictRoute == false) {
      loggy.debug("stability migration: changing strict-route from [$strictRoute] to [true]");
      await sharedPreferences.setBool("strict-route", true);
    }
  }
}

class PreferencesVersion4Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion4Migration(super.sharedPreferences);

  static const _siteRoutingExcludeKey = "site_routing_exclude_list";
  static const _siteRoutingModeKey = "site_routing_mode";
  static const _defaultExcludedSites = <String>[
    "gosuslugi.ru",
    "vk.com",
    "mail.ru",
    "max.ru",
    "vkvideo.ru",
    "rustore.ru",
    "rutube.ru",
    "ok.ru",
    "sber.ru",
    "tbank.ru",
    "alfabank.ru",
    "vtb.ru",
    "wildberries.ru",
    "ozon.ru",
    "lamoda.ru",
    "megamarket.ru",
    "avito.ru",
    "samokat.ru",
    "vkusvill.ru",
    "lenta.com",
    "magnit.com",
    "kinopoisk.ru",
    "ivi.ru",
    "start.ru",
    "kion.ru",
    "wink.ru",
    "2gis.ru",
    "hh.ru",
    "browser.yandex.ru",
    "yandex.ru",
    "pay.yandex.ru",
    "litres.ru",
    "rzd.ru",
    "cian.ru",
  ];

  @override
  Future<void> migrate() async {
    final excludeSites = sharedPreferences.getStringList(_siteRoutingExcludeKey);
    final shouldSeedExcludeSites = excludeSites == null || excludeSites.isEmpty;
    if (shouldSeedExcludeSites) {
      loggy.debug("site routing migration: seeding default excluded sites");
      await sharedPreferences.setStringList(_siteRoutingExcludeKey, _defaultExcludedSites);
    }

    final mode = sharedPreferences.getString(_siteRoutingModeKey);
    if (shouldSeedExcludeSites && (mode == null || mode.isEmpty || mode == "off")) {
      loggy.debug("site routing migration: changing mode from [$mode] to [exclude]");
      await sharedPreferences.setString(_siteRoutingModeKey, "exclude");
    }
  }
}

class PreferencesVersion5Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion5Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (!PlatformUtils.isAndroid) return;

    final strictRoute = sharedPreferences.getBool("strict-route");
    if (strictRoute == null || strictRoute == true) {
      loggy.debug("android speed migration: changing strict-route from [$strictRoute] to [false]");
      await sharedPreferences.setBool("strict-route", false);
    }

    final tunImplementation = sharedPreferences.getString("tun-implementation");
    if (tunImplementation == null || tunImplementation == "mixed") {
      loggy.debug("android speed migration: changing tun-implementation from [$tunImplementation] to [system]");
      await sharedPreferences.setString("tun-implementation", "system");
    }

    final mtu = sharedPreferences.getInt("mtu");
    if (mtu == null || mtu == 1400) {
      loggy.debug("android speed migration: changing mtu from [$mtu] to [1500]");
      await sharedPreferences.setInt("mtu", 1500);
    }
  }
}

class PreferencesVersion6Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion6Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (!PlatformUtils.isAndroid) return;

    final tunImplementation = sharedPreferences.getString("tun-implementation");
    if (tunImplementation != "gvisor") {
      loggy.debug("hiddify baseline migration: changing tun-implementation from [$tunImplementation] to [gvisor]");
      await sharedPreferences.setString("tun-implementation", "gvisor");
    }

    final mtu = sharedPreferences.getInt("mtu");
    if (mtu == null || mtu != 9000) {
      loggy.debug("hiddify baseline migration: changing mtu from [$mtu] to [9000]");
      await sharedPreferences.setInt("mtu", 9000);
    }

    final strictRoute = sharedPreferences.getBool("strict-route");
    if (strictRoute == null || strictRoute == false) {
      loggy.debug("hiddify baseline migration: changing strict-route from [$strictRoute] to [true]");
      await sharedPreferences.setBool("strict-route", true);
    }

    final bypassLan = sharedPreferences.getBool("bypass-lan");
    if (bypassLan == null || bypassLan == true) {
      loggy.debug("hiddify baseline migration: changing bypass-lan from [$bypassLan] to [false]");
      await sharedPreferences.setBool("bypass-lan", false);
    }

    final remoteDns = sharedPreferences.getString("remote-dns-address");
    if (remoteDns == null || remoteDns == "udp://1.1.1.1") {
      loggy.debug("hiddify baseline migration: changing remote-dns-address from [$remoteDns] to [tcp://8.8.8.8]");
      await sharedPreferences.setString("remote-dns-address", "tcp://8.8.8.8");
    }

    final balancerStrategy = sharedPreferences.getString("balancer-strategy");
    if (balancerStrategy == null || balancerStrategy == "sticky-sessions") {
      loggy.debug(
        "hiddify baseline migration: changing balancer-strategy from [$balancerStrategy] to [round-robin]",
      );
      await sharedPreferences.setString("balancer-strategy", "round-robin");
    }

    final fragmentPackets = sharedPreferences.getString("fragment-packets");
    if (fragmentPackets == null || fragmentPackets == "1-5") {
      loggy.debug("hiddify baseline migration: changing fragment-packets from [$fragmentPackets] to [tlshello]");
      await sharedPreferences.setString("fragment-packets", "tlshello");
    }
  }
}

class PreferencesVersion7Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion7Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (!PlatformUtils.isAndroid) return;

    final tunImplementation = sharedPreferences.getString("tun-implementation");
    if (tunImplementation == null || tunImplementation != "system") {
      loggy.debug("android stability migration: changing tun-implementation from [$tunImplementation] to [system]");
      await sharedPreferences.setString("tun-implementation", "system");
    }

    final mtu = sharedPreferences.getInt("mtu");
    if (mtu == null || mtu != 1500) {
      loggy.debug("android stability migration: changing mtu from [$mtu] to [1500]");
      await sharedPreferences.setInt("mtu", 1500);
    }

    final strictRoute = sharedPreferences.getBool("strict-route");
    if (strictRoute == null || strictRoute == true) {
      loggy.debug("android stability migration: changing strict-route from [$strictRoute] to [false]");
      await sharedPreferences.setBool("strict-route", false);
    }
  }
}
