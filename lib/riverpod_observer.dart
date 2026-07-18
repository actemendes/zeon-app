import 'dart:developer';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:hooks_riverpod/hooks_riverpod.dart';

class RiverpodObserver extends ProviderObserver {
  @override
  void didAddProvider(ProviderBase<Object?> provider, Object? value, ProviderContainer container) {
    if (kDebugMode) log('didAddProvider : ${provider.name ?? provider.runtimeType}');
  }

  @override
  void didDisposeProvider(ProviderBase<Object?> provider, ProviderContainer container) {
    if (kDebugMode) log('didDisposeProvider : ${provider.name ?? provider.runtimeType}');
  }

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (kDebugMode) log('didUpdateProvider : ${provider.name ?? provider.runtimeType}');
  }
}
