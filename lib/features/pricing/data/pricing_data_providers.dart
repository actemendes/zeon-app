import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/notifications/data/notification_data_providers.dart';
import 'package:zeon/features/notifications/data/notification_device_auth.dart';
import 'package:zeon/features/pricing/data/pricing_repository.dart';

final pricingRemoteDataSourceProvider = Provider<PricingRemoteDataSource>((ref) {
  return PricingApiDataSource(httpClient: ref.watch(httpClientProvider));
});

final pricingCacheStoreProvider = Provider<PricingCacheStore>((ref) {
  return SharedPreferencesPricingCacheStore(ref.watch(sharedPreferencesProvider).requireValue);
});

final pricingRepositoryProvider = Provider<PricingRepository>((ref) {
  final preferences = ref.watch(sharedPreferencesProvider).requireValue;
  return PricingRepository(
    remoteDataSource: ref.watch(pricingRemoteDataSourceProvider),
    cacheStore: ref.watch(pricingCacheStoreProvider),
    deviceAuth: PricingNotificationDeviceAuth(ref.watch(notificationDeviceAuthProvider)),
    currentUserId: () => int.tryParse((preferences.getString(MobileConnLinkImportService.prefUserId) ?? '').trim()),
  );
});

class PricingNotificationDeviceAuth implements PricingDeviceAuth {
  PricingNotificationDeviceAuth(this._delegate);

  final NotificationDeviceAuth _delegate;

  @override
  Future<String> readCachedDeviceJwt() => _delegate.readCachedDeviceJwt();

  @override
  Future<String> resolveDeviceJwt({bool forceRefresh = false}) =>
      forceRefresh ? _delegate.resolveDeviceJwt(forceRefresh: true) : _delegate.resolveDeviceJwt();
}

final pricingControllerProvider = StateNotifierProvider<PricingController, PricingUiState>((ref) {
  final controller = PricingController(ref.watch(pricingRepositoryProvider));
  controller.load();
  return controller;
});

class PricingController extends StateNotifier<PricingUiState> {
  PricingController(this._repository) : super(const PricingUiState(status: PricingUiStatus.loading));

  final PricingRepository _repository;
  bool _loading = false;

  Future<void> load() => _refresh(showInitialLoading: true);
  Future<void> refresh() => _refresh(showInitialLoading: false);

  Future<void> _refresh({required bool showInitialLoading}) async {
    if (_loading) return;
    _loading = true;

    final cached = await _repository.getCachedPricing();
    if (cached != null) {
      state = PricingUiState(
        status: showInitialLoading ? PricingUiStatus.content : PricingUiStatus.refreshing,
        catalog: cached,
      );
    } else if (showInitialLoading) {
      state = const PricingUiState(status: PricingUiStatus.loading);
    } else if (state.catalog != null) {
      state = state.copyWith(status: PricingUiStatus.refreshing);
    }

    try {
      final fresh = await _repository.refreshPricing();
      state = PricingUiState(status: PricingUiStatus.content, catalog: fresh);
    } catch (e) {
      final latestCached = await _repository.getCachedPricing();
      if (latestCached != null) {
        state = PricingUiState(
          status: PricingUiStatus.offlineCached,
          catalog: latestCached,
          errorMessage: _friendlyError(pricingFailureType(e)),
        );
      } else {
        state = PricingUiState(
          status: PricingUiStatus.errorWithoutCache,
          catalog: PricingCatalog(
            data: legacyBundledPricingData(),
            source: PricingCatalogSource.bundledFallback,
            fetchedAt: DateTime.now().toUtc(),
          ),
          errorMessage: _friendlyError(pricingFailureType(e)),
        );
      }
    } finally {
      _loading = false;
    }
  }

  static String _friendlyError(PricingFailureType type) {
    return switch (type) {
      PricingFailureType.unauthorized => 'Authorization expired. Pull to refresh or try again.',
      PricingFailureType.forbidden => 'This device is not linked to the current account.',
      PricingFailureType.rateLimited => 'Too many requests. Please try again later.',
      PricingFailureType.serverUnavailable => 'Pricing is temporarily unavailable.',
      PricingFailureType.network => 'Network is unavailable. Showing saved prices when possible.',
      PricingFailureType.invalidJson => 'Pricing response could not be read.',
      PricingFailureType.apiError => 'Pricing is temporarily unavailable.',
      PricingFailureType.unknown => 'Unable to refresh pricing right now.',
    };
  }
}

class PricingUiState {
  const PricingUiState({required this.status, this.catalog, this.errorMessage});

  final PricingUiStatus status;
  final PricingCatalog? catalog;
  final String? errorMessage;

  PricingUiState copyWith({PricingUiStatus? status, PricingCatalog? catalog, String? errorMessage}) {
    return PricingUiState(status: status ?? this.status, catalog: catalog ?? this.catalog, errorMessage: errorMessage);
  }
}

enum PricingUiStatus { loading, content, refreshing, offlineCached, errorWithoutCache }
