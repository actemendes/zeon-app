import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:protobuf/protobuf.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:zeon/core/haptic/haptic_service.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/utils/throttler.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/data/proxy_data_providers.dart';
import 'package:zeon/features/proxy/model/ip_info_entity.dart' as oldipinfo;
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/model/proxy_failure.dart';
import 'package:zeon/features/stats/data/stats_data_providers.dart';
import 'package:zeon/utils/riverpod_utils.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/init_signal.dart';

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
      // throw err; //zeon: remove exception to be logged
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
        .map(_activeProxyFromGroups);
    final selectorStream = proxyProvider.watchProxies().map((event) => event.getOrElse((l) => null)).startWith(null);
    final statsStream = ref
        .watch(statsRepositoryProvider)
        .watchStats()
        .map((event) => event.getOrElse((_) => SystemInfo.create()))
        .startWith(SystemInfo.create());

    yield* Rx.combineLatest3<OutboundInfo, OutboundGroup?, SystemInfo, OutboundInfo?>(
      activeProxyStream,
      selectorStream,
      statsStream,
      (activeProxy, selector, stats) {
        final resolvedProxy = _resolveDisplayProxy(activeProxy, selector, stats);
        final displayProxy = _isAutoBalancerSelected(selector)
            ? _asAutoBalancer(resolvedProxy, selector, stats)
            : resolvedProxy;
        if (_hasUsableDisplayProxy(displayProxy)) {
          return _lastDisplayProxy = displayProxy;
        }
        return _lastDisplayProxy;
      },
    ).where((event) => event != null).cast<OutboundInfo>();
  }

  final _urlTestThrottler = Throttler(const Duration(seconds: 1));
  OutboundInfo? _lastDisplayProxy;

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

  OutboundInfo _activeProxyFromGroups(List<OutboundGroup> groups) {
    if (groups.isEmpty) return OutboundInfo();

    final selector = _findGroup(groups, 'select') ?? groups.first;
    final selected = selector.selected.trim();
    final selectedGroup = _findGroup(groups, selected);
    final selectedGroupLeaf = _bestVisibleLeaf(selectedGroup?.items ?? const <OutboundInfo>[]);
    if (selectedGroupLeaf != null) return selectedGroupLeaf;

    final selectedSelectorItem = findOutboundByTagOrDisplay(selector.items, selected);
    if (_isDisplayableLeaf(selectedSelectorItem)) return selectedSelectorItem!;

    final selectorLeaf = _bestVisibleLeaf(selector.items);
    if (selectorLeaf != null) return selectorLeaf;

    for (final group in groups) {
      final leaf = _bestVisibleLeaf(group.items);
      if (leaf != null) return leaf;
    }

    return groups.first.items.firstOrNull ?? OutboundInfo();
  }

  OutboundGroup? _findGroup(Iterable<OutboundGroup> groups, String tag) {
    final normalized = tag.trim();
    if (normalized.isEmpty) return null;
    for (final group in groups) {
      if (group.tag.trim() == normalized) return group;
    }
    return null;
  }

  OutboundInfo _resolveDisplayProxy(OutboundInfo activeProxy, OutboundGroup? selector, SystemInfo stats) {
    if (!_isEmptyOutbound(activeProxy) && !_isAutoOutbound(activeProxy)) return activeProxy;

    final fallback = _realOutbound(activeProxy, selector, stats);
    if (fallback != null) return fallback;

    if (!_isEmptyOutbound(activeProxy)) return activeProxy;

    final currentOutbound = extractRealOutboundTag(stats.currentOutbound) ?? stats.currentOutbound.trim();
    if (currentOutbound.isEmpty) return activeProxy;

    return OutboundInfo(
      tag: currentOutbound,
      tagDisplay: currentOutbound,
      type: 'proxy',
      isSelected: true,
      isVisible: true,
    );
  }

  bool _isEmptyOutbound(OutboundInfo outbound) {
    return outbound.tag.trim().isEmpty &&
        outbound.tagDisplay.trim().isEmpty &&
        (!outbound.hasGroupSelectedTag() || outbound.groupSelectedTag.trim().isEmpty) &&
        (!outbound.hasGroupSelectedTagDisplay() || outbound.groupSelectedTagDisplay.trim().isEmpty);
  }

  bool _hasUsableDisplayProxy(OutboundInfo outbound) {
    if (_isEmptyOutbound(outbound)) return false;
    if (_isDisplayableLeaf(outbound)) return true;
    if (!_isAutoOutbound(outbound)) return false;

    final realName = _firstNonEmpty([
      if (outbound.hasGroupSelectedTagDisplay()) outbound.groupSelectedTagDisplay,
      if (outbound.hasGroupSelectedTag()) outbound.groupSelectedTag,
      extractRealOutboundTag(outbound.tagDisplay),
    ]);
    final hasRealName = realName != null && !_isTechnicalOrPlaceholderName(realName);
    final hasUsablePing = outbound.hasUrlTestDelay() && outbound.urlTestDelay > 0 && outbound.urlTestDelay < 65000;
    final hasHealth = outbound.hasHealthScore() && outbound.healthScore > 0;
    return hasRealName || hasUsablePing || hasHealth;
  }

  OutboundInfo _asAutoBalancer(OutboundInfo activeProxy, OutboundGroup? selector, SystemInfo stats) {
    final realOutbound = _realOutbound(activeProxy, selector, stats);
    final info = (realOutbound ?? activeProxy).deepCopy()
      ..tag = _autoBalancerTag
      ..type = "balancer"
      ..tagDisplay = _autoBalancerTag
      ..isSelected = true
      ..isGroup = true;
    if (realOutbound != null) {
      info.groupSelectedTag = realOutbound.tag;
      info.groupSelectedTagDisplay = realOutbound.tagDisplay;
    }
    return info;
  }

  OutboundInfo? _realOutbound(OutboundInfo activeProxy, OutboundGroup? selector, SystemInfo stats) {
    final items = selector?.items ?? const <OutboundInfo>[];
    final autoItem = _selectedAutoItem(selector);
    final selectedLeaf = _selectedLeafItem(selector);
    final candidates = <String?>[
      if (activeProxy.hasGroupSelectedTag()) activeProxy.groupSelectedTag,
      if (activeProxy.hasGroupSelectedTagDisplay()) activeProxy.groupSelectedTagDisplay,
      if (autoItem?.hasGroupSelectedTag() == true) autoItem?.groupSelectedTag,
      if (autoItem?.hasGroupSelectedTagDisplay() == true) autoItem?.groupSelectedTagDisplay,
      selectedLeaf?.tag,
      selectedLeaf?.tagDisplay,
      extractRealOutboundTag(stats.currentOutbound),
      stats.currentOutbound,
      extractRealOutboundTag(activeProxy.tagDisplay),
      extractRealOutboundTag(autoItem?.tagDisplay ?? ''),
    ];

    for (final candidate in candidates) {
      final outbound = findOutboundByTagOrDisplay(items, candidate);
      if (_isDisplayableLeaf(outbound)) return outbound;
    }

    final syntheticName = _firstNonEmpty([
      if (autoItem?.hasGroupSelectedTagDisplay() == true) autoItem?.groupSelectedTagDisplay,
      if (autoItem?.hasGroupSelectedTag() == true) autoItem?.groupSelectedTag,
      extractRealOutboundTag(stats.currentOutbound),
      stats.currentOutbound,
    ]);
    if (syntheticName != null && !_isTechnicalOrPlaceholderName(syntheticName)) {
      return OutboundInfo(
        tag: syntheticName,
        tagDisplay: syntheticName,
        type: 'proxy',
        isSelected: true,
        isVisible: true,
      );
    }

    return _bestVisibleLeaf(items);
  }

  OutboundInfo? _selectedAutoItem(OutboundGroup? selector) {
    final items = selector?.items ?? const <OutboundInfo>[];
    final selected = selector?.selected.trim();
    final selectedItem = findOutboundByTagOrDisplay(items, selected);
    if (_isAutoOutbound(selectedItem)) return selectedItem;
    for (final item in items) {
      if (item.isSelected && _isAutoOutbound(item)) return item;
    }
    for (final item in items) {
      if (_isAutoOutbound(item)) return item;
    }
    return null;
  }

  OutboundInfo? _selectedLeafItem(OutboundGroup? selector) {
    final items = selector?.items ?? const <OutboundInfo>[];
    final selected = findOutboundByTagOrDisplay(items, selector?.selected);
    if (_isDisplayableLeaf(selected)) return selected;
    for (final item in items) {
      if (item.isSelected && _isDisplayableLeaf(item)) return item;
    }
    return null;
  }

  OutboundInfo? _bestVisibleLeaf(Iterable<OutboundInfo> items) {
    final candidates = items.where(_isDisplayableLeaf).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final successCompare = _successRank(b).compareTo(_successRank(a));
      if (successCompare != 0) return successCompare;
      final scoreCompare = _healthScore(b).compareTo(_healthScore(a));
      if (scoreCompare != 0) return scoreCompare;
      return _delay(a).compareTo(_delay(b));
    });
    return candidates.first;
  }

  bool _isAutoOutbound(OutboundInfo? item) =>
      item != null && (_isAutoBalancerTag(item.tag) || isAutoSelectedOutbound(item));

  bool _isDisplayableLeaf(OutboundInfo? item) {
    if (item == null) return false;
    if (item.isGroup || isAutoSelectedOutbound(item)) return false;
    if (!item.isVisible || item.tag.contains('§hide§') || item.tagDisplay.contains('§hide§')) return false;
    return !_isTechnicalOrPlaceholderName(item.tag) && !_isTechnicalOrPlaceholderName(item.tagDisplay);
  }

  bool _isTechnicalOrPlaceholderName(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    if (normalized == 'select' || normalized == 'selector') return true;
    if (_isAutoBalancerTag(normalized) || normalized == 'lowest' || normalized == 'urltest') return true;
    return normalized.contains('приобретите доступ') ||
        normalized.contains('buy access') ||
        normalized.contains('purchase access') ||
        normalized.contains('upgrade');
  }

  String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  int _successRank(OutboundInfo item) => item.success ? 1 : 0;

  int _healthScore(OutboundInfo item) => item.hasHealthScore() ? item.healthScore : 0;

  int _delay(OutboundInfo item) {
    final delay = item.hasUrlTestDelay() ? item.urlTestDelay : 65535;
    return delay > 0 ? delay : 65535;
  }
}
