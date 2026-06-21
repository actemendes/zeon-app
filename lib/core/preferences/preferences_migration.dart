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
      PreferencesVersion8Migration(sharedPreferences),
      PreferencesVersion9Migration(sharedPreferences),
      PreferencesVersion10Migration(sharedPreferences),
      PreferencesVersion11Migration(sharedPreferences),
      PreferencesVersion12Migration(sharedPreferences),
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

    final legacyExecuteConfigAsIs = sharedPreferences.getBool("execute-config-as-is");
    if (legacyExecuteConfigAsIs != null && !sharedPreferences.containsKey("enable-full-config")) {
      loggy.debug("migrating [execute-config-as-is] = [$legacyExecuteConfigAsIs] to [enable-full-config]");
      await sharedPreferences.setBool("enable-full-config", legacyExecuteConfigAsIs);
    }

    // Keep legacy key for backward compatibility with older app/core versions.
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
    // Kept for compatibility with already released versions.
    // Intentionally no-op now to preserve user-selected VPN behavior.
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

  @override
  Future<void> migrate() async {}
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
    if (mtu == null || mtu != 1500) {
      loggy.debug("hiddify baseline migration: changing mtu from [$mtu] to [1500]");
      await sharedPreferences.setInt("mtu", 1500);
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
      loggy.debug("hiddify baseline migration: changing balancer-strategy from [$balancerStrategy] to [round-robin]");
      await sharedPreferences.setString("balancer-strategy", "round-robin");
    }

    final fragmentPackets = sharedPreferences.getString("fragment-packets");
    if (fragmentPackets == null || fragmentPackets == "tlshello") {
      loggy.debug("hiddify baseline migration: changing fragment-packets from [$fragmentPackets] to [1-5]");
      await sharedPreferences.setString("fragment-packets", "1-5");
    }
  }
}

class PreferencesVersion7Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion7Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (!PlatformUtils.isAndroid) return;

    final tunImplementation = sharedPreferences.getString("tun-implementation");
    if (tunImplementation == null || tunImplementation != "gvisor") {
      loggy.debug("android stability migration: changing tun-implementation from [$tunImplementation] to [gvisor]");
      await sharedPreferences.setString("tun-implementation", "gvisor");
    }

    final mtu = sharedPreferences.getInt("mtu");
    if (mtu == null || mtu != 1500) {
      loggy.debug("android stability migration: changing mtu from [$mtu] to [1500]");
      await sharedPreferences.setInt("mtu", 1500);
    }

    final strictRoute = sharedPreferences.getBool("strict-route");
    if (strictRoute == null || strictRoute == false) {
      loggy.debug("android stability migration: changing strict-route from [$strictRoute] to [true]");
      await sharedPreferences.setBool("strict-route", true);
    }
  }
}

class PreferencesVersion8Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion8Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    if (!PlatformUtils.isAndroid) return;

    final tunImplementation = sharedPreferences.getString("tun-implementation");
    if (tunImplementation == null || tunImplementation != "gvisor") {
      loggy.debug("baseline v8: changing tun-implementation from [$tunImplementation] to [gvisor]");
      await sharedPreferences.setString("tun-implementation", "gvisor");
    }

    final mtu = sharedPreferences.getInt("mtu");
    if (mtu == null || mtu != 1500) {
      loggy.debug("baseline v8: changing mtu from [$mtu] to [1500]");
      await sharedPreferences.setInt("mtu", 1500);
    }

    final strictRoute = sharedPreferences.getBool("strict-route");
    if (strictRoute == null || strictRoute == false) {
      loggy.debug("baseline v8: changing strict-route from [$strictRoute] to [true]");
      await sharedPreferences.setBool("strict-route", true);
    }
  }
}

class PreferencesVersion9Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion9Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {}
}

class PreferencesVersion10Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion10Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    final canonical = sharedPreferences.getBool("enable-full-config");
    final legacy = sharedPreferences.getBool("execute-config-as-is");

    if (canonical == null && legacy != null) {
      loggy.debug("v10: copying [execute-config-as-is]=$legacy to [enable-full-config]");
      await sharedPreferences.setBool("enable-full-config", legacy);
    } else if (canonical != null && legacy == null) {
      loggy.debug("v10: copying [enable-full-config]=$canonical to [execute-config-as-is]");
      await sharedPreferences.setBool("execute-config-as-is", canonical);
    }
  }
}

class PreferencesVersion11Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion11Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    final balancerStrategy = sharedPreferences.getString("balancer-strategy");
    if (balancerStrategy == null || balancerStrategy == "sticky-sessions") {
      loggy.debug("v11: changing balancer-strategy from [$balancerStrategy] to [round-robin]");
      await sharedPreferences.setString("balancer-strategy", "round-robin");
    }

    final bypassLan = sharedPreferences.getBool("bypass-lan");
    if (bypassLan == null || bypassLan == false) {
      loggy.debug("v11: changing bypass-lan from [$bypassLan] to [true]");
      await sharedPreferences.setBool("bypass-lan", true);
    }
  }
}

class PreferencesVersion12Migration extends PreferencesMigrationStep with InfraLogger {
  PreferencesVersion12Migration(super.sharedPreferences);

  @override
  Future<void> migrate() async {
    final balancerStrategy = sharedPreferences.getString("balancer-strategy");
    if (balancerStrategy != "smart-active-auto") {
      loggy.debug("v12: changing balancer-strategy from [$balancerStrategy] to [smart-active-auto]");
      await sharedPreferences.setString("balancer-strategy", "smart-active-auto");
    }
  }
}
