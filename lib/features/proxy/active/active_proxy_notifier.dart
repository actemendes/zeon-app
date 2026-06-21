import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/utils/throttler.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/ip_info_entity.dart' as oldipinfo;
import 'package:hiddify/features/proxy/model/proxy_display_name.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/stats/data/stats_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'active_proxy_notifier.g.dart';

@riverpod
class IpInfoNotifier extends _$IpInfoNotifier with AppLogger {
  @override
  Future<oldipinfo.IpInfo> build() async {
    ref.disposeDelay(const Duration(seconds: 20));
    final cancelToken = CancelToken();
    Timer? timer;
    ref.onDispose(() {
      loggy.debug("disposing");
      cancelToken.cancel();
      timer?.cancel();
    });

    ref.listen(serviceRunningProvider, (_, next) => _idle = false);

    final autoCheck = ref.watch(Preferences.autoCheckIp);
    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    // loggy.debug(
    //   "idle? [$_idle], forced? [$_forceCheck], connected? [$serviceRunning]",
    // );
    if (!_forceCheck && !serviceRunning) {
      throw const ServiceNotRunning();
    } else if ((_idle && !_forceCheck) || (!_forceCheck && serviceRunning && !autoCheck)) {
      throw const UnknownIp();
    }

    _forceCheck = false;
    final info = await ref.watch(proxyRepositoryProvider).getCurrentIpInfo(cancelToken).getOrElse((err) {
      loggy.warning("error getting proxy ip info", err, StackTrace.current);
      // throw err; //hiddify: remove exception to be logged
      throw const UnknownIp();
    }).run();

    timer = Timer(const Duration(seconds: 10), () {
      loggy.debug("entering idle mode");
      _idle = true;
      ref.invalidateSelf();
    });

    return info;
  }

  bool _idle = false;
  bool _forceCheck = false;

  Future<void> refresh() async {
    if (state.isLoading) return;
    loggy.debug("refreshing");
    state = const AsyncLoading();
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    _forceCheck = true;
    ref.invalidateSelf();
  }
}

@Riverpod(keepAlive: true)
class ActiveProxyNotifier extends _$ActiveProxyNotifier with AppLogger {
  static const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");
  static const _autoBalancerTag = "balance";

  bool get _useMockProxyFlow => kIsWeb && kDebugMode && _debugSeedProfileEnabled;

  @override
  Stream<OutboundInfo> build() async* {
    // ref.disposeDelay(const Duration(seconds: 20));
    if (!_useMockProxyFlow) {
      ref.watch(coreRestartSignalProvider);
    }
    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    if (!serviceRunning) {
      throw const ServiceNotRunning();
    }
    final proxyProvider = ref.watch(proxyRepositoryProvider);
    final activeProxyStream = proxyProvider
        .watchActiveProxies()
        .map((event) => event.getOrElse((l) => List<OutboundGroup>.empty()))
        .map((event) => event.firstOrNull?.items.first ?? OutboundInfo());
    final selectorStream = proxyProvider.watchProxies().map((event) => event.getOrElse((l) => null)).startWith(null);
    final statsStream = ref
        .watch(statsRepositoryProvider)
        .watchStats()
        .map((event) => event.getOrElse((_) => SystemInfo.create()))
        .startWith(SystemInfo.create());

    yield* Rx.combineLatest3<OutboundInfo, OutboundGroup?, SystemInfo, OutboundInfo>(
      activeProxyStream,
      selectorStream,
      statsStream,
      (activeProxy, selector, stats) {
        if (_isAutoBalancerSelected(selector)) {
          return _asAutoBalancer(activeProxy, selector, stats);
        }
        return activeProxy;
      },
    );
  }

  final _urlTestThrottler = Throttler(const Duration(seconds: 1));

  Future<void> urlTest(String? groupTag_) async {
    final groupTag = groupTag_ ?? "";
    await Future<void>.delayed(Duration.zero);
    _urlTestThrottler(() async {
      if (state case AsyncData()) {
        await ref.read(hapticServiceProvider.notifier).lightImpact();
        await ref.read(proxyRepositoryProvider).urlTest(groupTag).getOrElse((err) {
          loggy.warning("error testing group", err);
          throw err;
        }).run();
      }
    });
  }

  bool _isAutoBalancerSelected(OutboundGroup? group) {
    if (group == null) return false;
    if (_isAutoBalancerTag(group.selected)) return true;
    return group.items.any((item) => item.isSelected && _isAutoBalancerTag(item.tag));
  }

  bool _isAutoBalancerTag(String tag) => tag.trim().toLowerCase() == _autoBalancerTag;

  OutboundInfo _asAutoBalancer(OutboundInfo activeProxy, OutboundGroup? selector, SystemInfo stats) {
    final realOutbound = _realOutbound(activeProxy, selector, stats);
    return activeProxy.copyWith((info) {
      info.tag = _autoBalancerTag;
      info.type = "balancer";
      info.tagDisplay = _autoBalancerTag;
      if (realOutbound != null) {
        info.groupSelectedTag = realOutbound.tag;
        info.groupSelectedTagDisplay = realOutbound.tagDisplay;
      }
      info.isSelected = true;
      info.isGroup = true;
    });
  }

  OutboundInfo? _realOutbound(OutboundInfo activeProxy, OutboundGroup? selector, SystemInfo stats) {
    final items = selector?.items ?? const <OutboundInfo>[];
    final realTag = activeProxy.hasGroupSelectedTag() ? activeProxy.groupSelectedTag.trim() : '';
    final fromGroupSelection =
        findOutboundByTagOrDisplay(items, realTag) ??
        findOutboundByTagOrDisplay(
          items,
          activeProxy.hasGroupSelectedTagDisplay() ? activeProxy.groupSelectedTagDisplay : null,
        );
    if (fromGroupSelection != null) return fromGroupSelection;

    final fromStats = extractRealOutboundTag(stats.currentOutbound);
    final fromStatsItem = findOutboundByTagOrDisplay(items, fromStats);
    if (fromStatsItem != null) return fromStatsItem;

    return findOutboundByTagOrDisplay(items, extractRealOutboundTag(activeProxy.tagDisplay));
  }
}
