import 'package:flutter/foundation.dart';
import 'package:loggy/loggy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/utils/platform_utils.dart';

@immutable
class NetworkDiagnosticVariant {
  const NetworkDiagnosticVariant({
    this.disableTrafficHooks = false,
    this.disableUdpProbe = false,
    this.forceIpv4 = false,
    this.disableQuic = false,
    this.overrideMtu = 0,
    this.enableRouteTrace = false,
  });

  final bool disableTrafficHooks;
  final bool disableUdpProbe;
  final bool forceIpv4;
  final bool disableQuic;
  final int overrideMtu;
  final bool enableRouteTrace;

  bool get trafficHooksEnabled => !disableTrafficHooks;

  NetworkDiagnosticVariant copyWith({
    bool? disableTrafficHooks,
    bool? disableUdpProbe,
    bool? forceIpv4,
    bool? disableQuic,
    int? overrideMtu,
    bool? enableRouteTrace,
  }) {
    return NetworkDiagnosticVariant(
      disableTrafficHooks: disableTrafficHooks ?? this.disableTrafficHooks,
      disableUdpProbe: disableUdpProbe ?? this.disableUdpProbe,
      forceIpv4: forceIpv4 ?? this.forceIpv4,
      disableQuic: disableQuic ?? this.disableQuic,
      overrideMtu: overrideMtu ?? this.overrideMtu,
      enableRouteTrace: enableRouteTrace ?? this.enableRouteTrace,
    );
  }

  String describe({required bool udpProbeEffective}) {
    return "[DiagnosticVariant] "
        "traffic_hooks=$trafficHooksEnabled "
        "disable_traffic_hooks=$disableTrafficHooks "
        "udp_probe=$udpProbeEffective "
        "disable_udp_probe=$disableUdpProbe "
        "force_ipv4=$forceIpv4 "
        "disable_quic=$disableQuic "
        "mtu=${overrideMtu > 0 ? overrideMtu : "current"} "
        "route_trace=$enableRouteTrace";
  }
}

abstract final class NetworkDiagnosticVariantStore {
  static const disableTrafficHooksKey = "debug.network.disable_zeon_traffic_hooks";
  static const disableUdpProbeKey = "debug.network.disable_udp_probe";
  static const forceIpv4Key = "debug.network.force_ipv4";
  static const disableQuicKey = "debug.network.disable_quic";
  static const overrideMtuKey = "debug.network.override_mtu";
  static const enableRouteTraceKey = "debug.network.enable_route_trace";

  static const current = NetworkDiagnosticVariant(enableRouteTrace: true);
  static const withoutTrafficHooks = NetworkDiagnosticVariant(disableTrafficHooks: true, enableRouteTrace: true);
  static const withoutUdpProbe = NetworkDiagnosticVariant(disableUdpProbe: true, enableRouteTrace: true);
  static const quicDisabled = NetworkDiagnosticVariant(disableQuic: true, enableRouteTrace: true);
  static const ipv4Only = NetworkDiagnosticVariant(forceIpv4: true, enableRouteTrace: true);
  static const mtu1400 = NetworkDiagnosticVariant(overrideMtu: 1400, enableRouteTrace: true);
  static const mtu1380 = NetworkDiagnosticVariant(overrideMtu: 1380, enableRouteTrace: true);
  static const mtu1280 = NetworkDiagnosticVariant(overrideMtu: 1280, enableRouteTrace: true);

  static bool get isAvailable => kDebugMode && PlatformUtils.isAndroid;

  static NetworkDiagnosticVariant read(SharedPreferences preferences) {
    if (!isAvailable) return const NetworkDiagnosticVariant();
    return NetworkDiagnosticVariant(
      disableTrafficHooks: preferences.getBool(disableTrafficHooksKey) ?? false,
      disableUdpProbe: preferences.getBool(disableUdpProbeKey) ?? false,
      forceIpv4: preferences.getBool(forceIpv4Key) ?? false,
      disableQuic: preferences.getBool(disableQuicKey) ?? false,
      overrideMtu: preferences.getInt(overrideMtuKey) ?? 0,
      enableRouteTrace: preferences.getBool(enableRouteTraceKey) ?? false,
    );
  }

  static Future<void> write(SharedPreferences preferences, NetworkDiagnosticVariant variant) async {
    await preferences.setBool(disableTrafficHooksKey, variant.disableTrafficHooks);
    await preferences.setBool(disableUdpProbeKey, variant.disableUdpProbe);
    await preferences.setBool(forceIpv4Key, variant.forceIpv4);
    await preferences.setBool(disableQuicKey, variant.disableQuic);
    await preferences.setInt(overrideMtuKey, variant.overrideMtu);
    await preferences.setBool(enableRouteTraceKey, variant.enableRouteTrace);
  }

  static Future<void> reset(SharedPreferences preferences) async {
    await write(preferences, const NetworkDiagnosticVariant());
  }

  static void logVariant(NetworkDiagnosticVariant variant, {required bool udpProbeEffective, String source = "ui"}) {
    Loggy("network-diagnostics").info("${variant.describe(udpProbeEffective: udpProbeEffective)} source=$source");
  }
}
