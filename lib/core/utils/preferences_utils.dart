import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/utils/custom_loggers.dart';

class PreferencesEntry<T, P> with InfraLogger {
  PreferencesEntry({
    required this.preferences,
    required this.key,
    required this.defaultValue,
    this.mapFrom,
    this.mapTo,
    this.validator,
  });

  final SharedPreferences preferences;
  final String key;
  final T defaultValue;
  final T Function(P value)? mapFrom;
  final P Function(T value)? mapTo;
  final bool Function(T value)? validator;

  T read() {
    try {
      // loggy.debug("getting persisted preference [$key]($T)");
      final T value;
      if (mapFrom != null) {
        final persisted = preferences.get(key) as P?;
        if (persisted == null) {
          value = defaultValue;
        } else {
          value = mapFrom!(persisted);
        }
      } else if (T == List<String>) {
        final storedValue = preferences.getString(key);
        value = storedValue == null ? defaultValue : storedValue.split(";") as T;
      } else {
        value = preferences.get(key) as T? ?? defaultValue;
      }

      if (validator?.call(value) ?? true) return value;
      return defaultValue;
    } catch (e, stackTrace) {
      loggy.warning("error getting preference[$key]: $e", e, stackTrace);
      return defaultValue;
    }
  }

  Future<bool> write(T value) async {
    Object? mapped = value;
    if (mapTo != null) {
      mapped = mapTo!(value);
    }
    // Preference values may contain credentials or complete proxy configs.
    loggy.debug("updating preference [$key]($T)");
    try {
      if (!(validator?.call(value) ?? true)) {
        loggy.warning("invalid value for preference [$key]($T)");
        return false;
      }

      return switch (mapped) {
        final String value => await preferences.setString(key, value),
        final bool value => await preferences.setBool(key, value),
        final int value => await preferences.setInt(key, value),
        final double value => await preferences.setDouble(key, value),
        final List<String> value => await preferences.setString(key, value.join(";")),
        _ => throw const FormatException("Invalid Type"),
      };
    } catch (e, stackTrace) {
      loggy.warning("error updating preference[$key]: $e", e, stackTrace);
      return false;
    }
  }

  Future<T?> writeRaw(P input) async {
    final T value;
    if (mapFrom != null) {
      value = mapFrom!(input);
    } else {
      value = input as T;
    }
    if (await write(value)) return value;
    return null;
  }

  Future<void> remove() async {
    try {
      await preferences.remove(key);
    } catch (e, stackTrace) {
      loggy.warning("error removing preference[$key]: $e", e, stackTrace);
    }
  }
}

class PreferencesNotifier<T, P> extends StateNotifier<T> {
  PreferencesNotifier._({required Ref ref, required this.entry, this.overrideValue, this.possibleValues})
    : _ref = ref,
      super(overrideValue ?? entry.read());

  final Ref _ref;
  final PreferencesEntry<T, P> entry;
  final T? overrideValue;
  final List<T>? possibleValues;
  late final LatestPreferenceWriteCoordinator<T> _writeCoordinator = LatestPreferenceWriteCoordinator<T>(
    persist: entry.write,
    commit: (value) => state = value,
  );

  static StateNotifierProvider<PreferencesNotifier<T, P>, T> create<T, P>(
    String key,
    T defaultValue, {
    T Function(Ref ref)? defaultValueFunction,
    T Function(P value)? mapFrom,
    P Function(T value)? mapTo,
    bool Function(T value)? validator,
    T? overrideValue,
    List<T>? possibleValues,
  }) => StateNotifierProvider(
    (ref) => PreferencesNotifier._(
      ref: ref,
      entry: PreferencesEntry<T, P>(
        preferences: ref.read(sharedPreferencesProvider).requireValue,
        key: key,
        defaultValue: defaultValueFunction?.call(ref) ?? defaultValue,
        mapFrom: mapFrom,
        mapTo: mapTo,
        validator: validator,
      ),
      overrideValue: overrideValue,
      possibleValues: possibleValues,
    ),
  );

  static AutoDisposeStateNotifierProvider<PreferencesNotifier<T, P>, T> createAutoDispose<T, P>(
    String key,
    T defaultValue, {
    T Function(P value)? mapFrom,
    P Function(T value)? mapTo,
    bool Function(T value)? validator,
    T? overrideValue,
  }) => StateNotifierProvider.autoDispose(
    (ref) => PreferencesNotifier._(
      ref: ref,
      entry: PreferencesEntry<T, P>(
        preferences: ref.read(sharedPreferencesProvider).requireValue,
        key: key,
        defaultValue: defaultValue,
        mapFrom: mapFrom,
        mapTo: mapTo,
        validator: validator,
      ),
      overrideValue: overrideValue,
    ),
  );

  P raw() {
    final value = overrideValue ?? state;
    if (entry.mapTo != null) return entry.mapTo!(value);
    return value as P;
  }

  Future<void> updateRaw(P input) async {
    final value = await entry.writeRaw(input);
    if (value != null) state = value;
  }

  Future<void> update(T value) {
    return _writeCoordinator.update(value);
  }

  /// The newest requested value, including a write that has not completed.
  /// Lifecycle conflict resolution must compare ownership against this value,
  /// not only against [state], which intentionally commits normal updates
  /// after persistence succeeds.
  T get latestRequestedValue => _writeCoordinator.latestRequested ?? state;

  /// Updates the in-memory owner immediately, then persists it with the same
  /// latest-write-wins ordering as [update]. This is reserved for lifecycle
  /// intent that must be observable before the corresponding native status is
  /// published; disk I/O must not make a proven platform transition look
  /// stale to synchronous consumers.
  Future<void> updateOptimistically(T value) {
    state = value;
    return _writeCoordinator.update(value);
  }

  Future<void> reset() async {
    _writeCoordinator.invalidate();
    await entry.remove();
    _ref.invalidateSelf();
  }
}

/// Lets newer preference writes proceed even if an older platform write is
/// hung, while still repairing persistence if that older write eventually
/// completes after the newer value.
///
/// This is intentionally latest-wins instead of a serial Future chain: a
/// timeout at a lifecycle caller cannot cancel SharedPreferences I/O, and a
/// never-completing head of a serial queue would otherwise poison every later
/// Start/Stop intent until process restart.
class LatestPreferenceWriteCoordinator<T> {
  LatestPreferenceWriteCoordinator({required this.persist, required this.commit});

  final Future<bool> Function(T value) persist;
  final void Function(T value) commit;

  int _revision = 0;
  ({int revision, T value})? _latest;

  T? get latestRequested => _latest?.value;

  Future<void> update(T value) {
    final request = (revision: ++_revision, value: value);
    _latest = request;
    return _persist(request);
  }

  void invalidate() {
    _revision += 1;
    _latest = null;
  }

  Future<void> _persist(({int revision, T value}) request) async {
    final succeeded = await persist(request.value);
    if (!succeeded) return;

    final latest = _latest;
    if (latest == null) return;
    if (latest.revision == request.revision) {
      commit(request.value);
      return;
    }

    // The stale write may just have overwritten the latest value on disk.
    // Reassert the current value without making its caller wait for this old
    // operation. If another update wins meanwhile, the same revision check
    // will repair to that still-newer value.
    unawaited(_persist(latest));
  }
}
