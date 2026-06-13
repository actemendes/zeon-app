import 'dart:async';

import 'package:dartx/dartx.dart';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_display_name.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'proxies_overview_notifier.g.dart';

enum ProxiesSort {
  unsorted,
  name,
  delay,
  usage;

  String present(TranslationsEn t) => switch (this) {
    ProxiesSort.unsorted => t.pages.proxies.sortOptions.unsorted,
    ProxiesSort.name => t.pages.proxies.sortOptions.name,
    ProxiesSort.delay => t.pages.proxies.sortOptions.delay,
    ProxiesSort.usage => t.pages.proxies.sortOptions.usage,
  };
}

List<OutboundInfo> sortProxyItemsByCombinedHealth(Iterable<OutboundInfo> items) {
  final indexed = <({int index, OutboundInfo item})>[];
  var index = 0;
  for (final item in items) {
    indexed.add((index: index, item: item));
    index++;
  }

  indexed.sort((a, b) {
    final result = compareProxyByCombinedHealthForDisplay(a.item, b.item);
    if (result != 0) return result;
    return a.index.compareTo(b.index);
  });

  return [for (final entry in indexed) entry.item];
}

int compareProxyByCombinedHealthForDisplay(OutboundInfo a, OutboundInfo b) {
  final specialRank = _compareInt(_proxySpecialRank(a), _proxySpecialRank(b));
  if (specialRank != 0) return specialRank;

  final bucketRank = _compareInt(_healthBucketRank(a), _healthBucketRank(b));
  if (bucketRank != 0) return bucketRank;

  final combinedRank = _compareIntDesc(_displayCombinedScore(a), _displayCombinedScore(b));
  if (combinedRank != 0) return combinedRank;

  final speedRank = _compareIntDesc(a.speedScore, b.speedScore);
  if (speedRank != 0) return speedRank;

  final qualityRank = _compareIntDesc(a.qualityScore, b.qualityScore);
  if (qualityRank != 0) return qualityRank;

  return _compareDelay(a.urlTestDelay, b.urlTestDelay);
}

int _proxySpecialRank(OutboundInfo proxy) {
  if (_isAutoSelectionProxy(proxy)) return 0;
  if (proxy.isGroup) return 1;
  return 2;
}

bool _isAutoSelectionProxy(OutboundInfo proxy) {
  return isAutoSelectionProxyOption(tag: proxy.tag, tagDisplay: proxy.tagDisplay);
}

int _healthBucketRank(OutboundInfo proxy) {
  final level = _normalizedHealthLevel(proxy);
  return switch (level) {
    "excellent" || "good" || "fast" || "normal" => 0,
    "medium" || "slow" => 1,
    "weak" || "very_slow" || "very-slow" => 2,
    "bad" || "failed" => 4,
    _ => 3,
  };
}

String _normalizedHealthLevel(OutboundInfo proxy) {
  final combined = proxy.combinedHealthLevel.trim().toLowerCase();
  if (combined.isNotEmpty) return combined;
  final external = proxy.externalHealthLevel.trim().toLowerCase();
  if (external.isNotEmpty) return external;
  final quality = proxy.qualityLevel.trim().toLowerCase();
  if (quality.isNotEmpty) return quality;
  return "unknown";
}

int _displayCombinedScore(OutboundInfo proxy) {
  if (proxy.combinedHealthScore > 0) return proxy.combinedHealthScore;
  if (proxy.externalHealthScore > 0) return proxy.externalHealthScore;
  if (proxy.qualityScore > 0) return proxy.qualityScore;
  return switch (_normalizedHealthLevel(proxy)) {
    "excellent" => 95,
    "good" || "fast" || "normal" => 75,
    "medium" || "slow" => 55,
    "weak" || "very_slow" || "very-slow" => 25,
    "bad" || "failed" => 0,
    _ => -1,
  };
}

int _compareDelay(int a, int b) {
  final aValid = _hasUsableDelay(a);
  final bValid = _hasUsableDelay(b);
  if (aValid && !bValid) return -1;
  if (!aValid && bValid) return 1;
  if (!aValid && !bValid) return 0;
  return a.compareTo(b);
}

bool _hasUsableDelay(int delay) => delay > 0 && delay < 65000;

int _compareInt(int a, int b) => a.compareTo(b);

int _compareIntDesc(int a, int b) => b.compareTo(a);

@Riverpod(keepAlive: true)
class ProxiesSortNotifier extends _$ProxiesSortNotifier with AppLogger {
  late final _pref = PreferencesEntry(
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    key: "proxies_sort_mode",
    defaultValue: ProxiesSort.delay,
    mapFrom: ProxiesSort.values.byName,
    mapTo: (value) => value.name,
  );

  @override
  ProxiesSort build() {
    final sortBy = _pref.read();
    loggy.info("sort proxies by: [${sortBy.name}]");
    return sortBy;
  }

  Future<void> update(ProxiesSort value) {
    state = value;
    return _pref.write(value);
  }
}

@riverpod
class ProxiesOverviewNotifier extends _$ProxiesOverviewNotifier with AppLogger {
  @override
  Stream<OutboundGroup?> build() async* {
    ref.disposeDelay(const Duration(seconds: 15));
    ref.watch(coreRestartSignalProvider);
    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    if (!serviceRunning) {
      throw const ServiceNotRunning();
    }
    final sortBy = ref.watch(proxiesSortNotifierProvider);
    // yield* ref
    //     .watch(proxyRepositoryProvider)
    //     .watchProxies()
    //     .throttleTime(
    //       const Duration(milliseconds: 100),
    //       leading: false,
    //       trailing: true,
    //     )
    //     .map(
    //       (event) => event.getOrElse(
    //         (err) {
    //           loggy.warning("error receiving proxies", err);
    //           throw err;
    //         },
    //       ),
    //     )
    //     .asyncMap((proxies) async => _sortOutbounds(proxies, sortBy));
    yield* ref
        .watch(proxyRepositoryProvider)
        .watchProxies()
        .map(
          (event) => event.getOrElse((err) {
            loggy.warning("error receiving proxies", err);
            throw err;
          }),
        )
        .asyncMap((proxies) async => await _sortOutbounds(proxies, sortBy));
  }

  // Future<List<OutboundGroup>> _sortOutbounds(
  //   List<OutboundGroup> proxies,
  //   ProxiesSort sortBy,
  // ) async {
  //   final groupWithSelected = {
  //     for (final o in proxies) o.tag: o.selected,
  //   };
  //   final sortedProxies = <OutboundGroup>[];
  //   for (final group in proxies) {
  //     final sortedItems = switch (sortBy) {
  //       ProxiesSort.name => group.items.sortedWith((a, b) {
  //           if (a.isGroup && !b.isGroup) return -1;
  //           if (!a.isGroup && b.isGroup) return 1;
  //           return a.tag.compareTo(b.tag);
  //         }),
  //       ProxiesSort.delay => group.items.sortedWith((a, b) {
  //           if (a.isGroup && !b.isGroup) return -1;
  //           if (!a.isGroup && b.isGroup) return 1;

  //           final ai = a.urlTestDelay;
  //           final bi = b.urlTestDelay;
  //           if (ai == 0 && bi == 0) return -1;
  //           if (ai == 0 && bi > 0) return 1;
  //           if (ai > 0 && bi == 0) return -1;
  //           return ai.compareTo(bi);
  //         }),
  //       ProxiesSort.unsorted => group.items,
  //     };
  //     final items = <OutboundInfo>[];
  //     for (final item in sortedItems) {
  //       // if (groupWithSelected.keys.contains(item.tag)) {
  //       //   items.add(item.copyWith(selectedTag: groupWithSelected[item.tag]));
  //       // } else {
  //       items.add(item);
  //       // }
  //     }
  //     group.items.clear();
  //     group.items.addAll(items);
  //     sortedProxies.add(group);
  //   }
  //   return sortedProxies;
  // }

  Future<OutboundGroup?> _sortOutbounds(OutboundGroup? proxies, ProxiesSort sortBy) async {
    if (proxies == null) return null;

    final sortedItems = switch (sortBy) {
      ProxiesSort.name => proxies.items.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;
        return a.tag.compareTo(b.tag);
      }),
      ProxiesSort.delay => sortProxyItemsByCombinedHealth(proxies.items),
      ProxiesSort.unsorted => proxies.items,
      ProxiesSort.usage => proxies.items.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;
        return (b.upload + b.download).compareTo(a.upload + a.download);
      }),
    };
    final items = <OutboundInfo>[];
    for (final item in sortedItems) {
      if (shouldHideProxyOption(tag: item.tag, tagDisplay: item.tagDisplay)) {
        continue;
      }
      // if (groupWithSelected.keys.contains(item.tag)) {
      //   items.add(item.copyWith(selectedTag: groupWithSelected[item.tag]));
      // } else {
      items.add(item);
      // }
    }
    proxies.items.clear();
    proxies.items.addAll(items);
    return proxies;
  }

  // Future<void> changeProxy(String groupTag, String outboundTag) async {
  //   loggy.debug(
  //     "changing proxy, group: [$groupTag] - outbound: [$outboundTag]",
  //   );
  //   if (state case AsyncData(value: final outbounds)) {
  //     await ref.read(hapticServiceProvider.notifier).lightImpact();
  //     await ref.read(proxyRepositoryProvider).selectProxy(groupTag, outboundTag).getOrElse((err) {
  //       loggy.warning("error selecting outbound", err);
  //       throw err;
  //     }).run();
  //     final outboundg = outbounds.where((e) => e.tag == groupTag).firstOrNull;
  //     if (outboundg != null) {
  //       final newselected = outboundg.items.where((e) => e.tag == outboundTag).firstOrNull;
  //       if (newselected != null) {
  //         newselected.isSelected = true;
  //         outboundg.selected = newselected;
  //       }
  //     }
  //     state = AsyncData(
  //       [...outbounds],
  //     ).copyWithPrevious(state);
  //   }
  // }

  Future<void> changeProxy(String groupTag, String outboundTag) async {
    loggy.debug("changing proxy, group: [$groupTag] - outbound: [$outboundTag]");
    if (!state.hasValue) return;
    final outbounds = state.value!;
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await ref.read(proxyRepositoryProvider).selectProxy(groupTag, outboundTag).getOrElse((err) {
      loggy.warning("error selecting outbound", err);
      throw err;
    }).run();
    final newselected = outbounds.items.where((e) => e.tag == outboundTag).firstOrNull;
    if (newselected != null) {
      newselected.isSelected = true;
      outbounds.selected = newselected.tag;
      state = AsyncValue.data(outbounds);
    }
  }

  Future<void> urlTest(String groupTag) async {
    loggy.debug("testing group: [$groupTag]");
    if (state case AsyncData()) {
      await ref.read(hapticServiceProvider.notifier).lightImpact();
      await ref.read(proxyRepositoryProvider).urlTest(groupTag).getOrElse((err) {
        loggy.error("error testing group", err);
        throw err;
      }).run();
    }
  }
}
