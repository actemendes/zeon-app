import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/pricing/model/pricing_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class PricingRemoteDataSource {
  Future<PricingData> getPublicPricing();
  Future<PricingData> getPersonalizedPricing(String deviceJwt, {bool forceRefresh = false});
}

abstract interface class PricingCacheStore {
  Future<CachedPricing?> readPublic();
  Future<CachedPricing?> readPersonalized({required int? currentUserId});
  Future<void> writePublic(PricingData data, DateTime fetchedAt);
  Future<void> writePersonalized(PricingData data, DateTime fetchedAt, {required int currentUserId});
  Future<void> clearPersonalized();
}

abstract interface class PricingDeviceAuth {
  String peekCachedDeviceJwt();
  Future<String> resolveDeviceJwt({bool forceRefresh = false});
}

class PricingRepository {
  PricingRepository({
    required PricingRemoteDataSource remoteDataSource,
    required PricingCacheStore cacheStore,
    required PricingDeviceAuth deviceAuth,
    required int? Function() currentUserId,
    DateTime Function()? now,
  }) : _remoteDataSource = remoteDataSource,
       _cacheStore = cacheStore,
       _deviceAuth = deviceAuth,
       _currentUserId = currentUserId,
       _now = now ?? (() => DateTime.now().toUtc());

  final PricingRemoteDataSource _remoteDataSource;
  final PricingCacheStore _cacheStore;
  final PricingDeviceAuth _deviceAuth;
  final int? Function() _currentUserId;
  final DateTime Function() _now;

  Future<PricingCatalog?> getCachedPricing() async {
    final userId = _currentUserId();
    final personalized = await _cacheStore.readPersonalized(currentUserId: userId);
    if (personalized != null) {
      return PricingCatalog(
        data: personalized.data,
        source: PricingCatalogSource.personalizedCache,
        fetchedAt: personalized.fetchedAt,
      );
    }
    final public = await _cacheStore.readPublic();
    if (public != null) {
      return PricingCatalog(data: public.data, source: PricingCatalogSource.publicCache, fetchedAt: public.fetchedAt);
    }
    return null;
  }

  Future<PricingCatalog> getPublicPricing() async {
    final data = await _remoteDataSource.getPublicPricing();
    final fetchedAt = _now();
    await _cacheStore.writePublic(data, fetchedAt);
    return PricingCatalog(data: data, source: PricingCatalogSource.publicRemote, fetchedAt: fetchedAt);
  }

  Future<PricingCatalog> getPersonalizedPricing(String deviceJwt, {bool forceRefresh = false}) async {
    final data = await _remoteDataSource.getPersonalizedPricing(deviceJwt, forceRefresh: forceRefresh);
    final fetchedAt = _now();
    final userId = _currentUserId();
    if (userId != null && userId > 0) {
      await _cacheStore.writePersonalized(data, fetchedAt, currentUserId: userId);
    }
    return PricingCatalog(data: data, source: PricingCatalogSource.personalizedRemote, fetchedAt: fetchedAt);
  }

  Future<PricingCatalog> refreshPricing({bool forcePersonalizedJwtRefresh = false}) async {
    final cachedJwt = _deviceAuth.peekCachedDeviceJwt();
    if (cachedJwt.isEmpty && !forcePersonalizedJwtRefresh) {
      return getPublicPricing();
    }

    try {
      final jwt = forcePersonalizedJwtRefresh
          ? await _deviceAuth.resolveDeviceJwt(forceRefresh: true)
          : await _deviceAuth.resolveDeviceJwt();
      if (jwt.trim().isEmpty) {
        return getPublicPricing();
      }
      return await getPersonalizedPricing(jwt, forceRefresh: forcePersonalizedJwtRefresh);
    } on Object catch (e) {
      final statusCode = e is PricingRemoteException
          ? e.statusCode
          : e is DioException
          ? e.response?.statusCode
          : null;
      if (statusCode == 401 && !forcePersonalizedJwtRefresh) {
        final jwt = await _deviceAuth.resolveDeviceJwt(forceRefresh: true);
        if (jwt.trim().isNotEmpty) {
          return getPersonalizedPricing(jwt, forceRefresh: true);
        }
      }
      rethrow;
    }
  }

  Future<void> clearPersonalizedCache() => _cacheStore.clearPersonalized();
}

class PricingApiDataSource implements PricingRemoteDataSource {
  PricingApiDataSource({required DioHttpClient httpClient, Duration timeout = const Duration(seconds: 8)})
    : _httpClient = httpClient,
      _timeout = timeout;

  static const apiBaseUrl = MobileConnLinkImportService.apiBaseUrl;

  final DioHttpClient _httpClient;
  final Duration _timeout;

  @override
  Future<PricingData> getPublicPricing() async {
    final uri = Uri.parse(apiBaseUrl).resolve('/api/v1/pricing/public').toString();
    final response = await _httpClient
        .get<Map<String, dynamic>>(uri, headers: {'Accept': 'application/json'}, directOnly: true, disableRetry: true)
        .timeout(_timeout);
    return _parseResponse(response);
  }

  @override
  Future<PricingData> getPersonalizedPricing(String deviceJwt, {bool forceRefresh = false}) async {
    final token = deviceJwt.trim();
    if (token.isEmpty) throw const PricingRemoteException(type: PricingFailureType.unauthorized);
    final uri = Uri.parse(apiBaseUrl).resolve('/api/v1/pricing').toString();
    final response = await _httpClient
        .get<Map<String, dynamic>>(
          uri,
          headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
          directOnly: true,
          disableRetry: true,
        )
        .timeout(_timeout);
    return _parseResponse(response);
  }

  PricingData _parseResponse(Response<Map<String, dynamic>> response) {
    if (response.statusCode != 200) {
      throw PricingRemoteException(type: _failureTypeForStatus(response.statusCode), statusCode: response.statusCode);
    }
    final parsed = PricingResponse.parse(response.data);
    if (!parsed.ok || parsed.data == null) {
      throw PricingRemoteException(
        type: PricingFailureType.apiError,
        statusCode: response.statusCode,
        apiCode: parsed.error?.code,
        message: parsed.error?.message,
      );
    }
    return parsed.data!;
  }
}

class SharedPreferencesPricingCacheStore implements PricingCacheStore {
  SharedPreferencesPricingCacheStore(this._preferences);

  static const _publicBodyKey = 'pricing_public_cache_body';
  static const _publicFetchedAtKey = 'pricing_public_cache_fetched_at';
  static const _personalBodyKey = 'pricing_personal_cache_body';
  static const _personalFetchedAtKey = 'pricing_personal_cache_fetched_at';
  static const _personalUserIdKey = 'pricing_personal_cache_user_id';

  final SharedPreferences _preferences;

  @override
  Future<CachedPricing?> readPublic() async {
    return _read(bodyKey: _publicBodyKey, fetchedAtKey: _publicFetchedAtKey);
  }

  @override
  Future<CachedPricing?> readPersonalized({required int? currentUserId}) async {
    final cachedUserId = int.tryParse((_preferences.getString(_personalUserIdKey) ?? '').trim());
    if (cachedUserId == null || cachedUserId <= 0 || cachedUserId != currentUserId) {
      await clearPersonalized();
      return null;
    }
    return _read(bodyKey: _personalBodyKey, fetchedAtKey: _personalFetchedAtKey, userId: cachedUserId);
  }

  @override
  Future<void> writePublic(PricingData data, DateTime fetchedAt) async {
    await _preferences.setString(_publicBodyKey, jsonEncode(data.toJson()));
    await _preferences.setString(_publicFetchedAtKey, fetchedAt.toUtc().toIso8601String());
  }

  @override
  Future<void> writePersonalized(PricingData data, DateTime fetchedAt, {required int currentUserId}) async {
    await _preferences.setString(_personalBodyKey, jsonEncode(data.toJson()));
    await _preferences.setString(_personalFetchedAtKey, fetchedAt.toUtc().toIso8601String());
    await _preferences.setString(_personalUserIdKey, currentUserId.toString());
  }

  @override
  Future<void> clearPersonalized() async {
    await _preferences.remove(_personalBodyKey);
    await _preferences.remove(_personalFetchedAtKey);
    await _preferences.remove(_personalUserIdKey);
  }

  CachedPricing? _read({required String bodyKey, required String fetchedAtKey, int? userId}) {
    try {
      final raw = (_preferences.getString(bodyKey) ?? '').trim();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final fetchedAt = DateTime.tryParse((_preferences.getString(fetchedAtKey) ?? '').trim())?.toUtc();
      if (fetchedAt == null) return null;
      return CachedPricing(data: PricingData.parse(decoded), fetchedAt: fetchedAt, userId: userId);
    } catch (_) {
      return null;
    }
  }
}

class CachedPricing {
  const CachedPricing({required this.data, required this.fetchedAt, this.userId});

  final PricingData data;
  final DateTime fetchedAt;
  final int? userId;
}

class PricingCatalog {
  const PricingCatalog({required this.data, required this.source, required this.fetchedAt});

  final PricingData data;
  final PricingCatalogSource source;
  final DateTime fetchedAt;

  bool get isCache => source == PricingCatalogSource.publicCache || source == PricingCatalogSource.personalizedCache;
  bool get isBundledFallback => source == PricingCatalogSource.bundledFallback;
  bool get isPersonalized =>
      source == PricingCatalogSource.personalizedRemote || source == PricingCatalogSource.personalizedCache;
}

enum PricingCatalogSource { publicRemote, personalizedRemote, publicCache, personalizedCache, bundledFallback }

enum PricingFailureType {
  unauthorized,
  forbidden,
  rateLimited,
  serverUnavailable,
  network,
  invalidJson,
  apiError,
  unknown,
}

class PricingRemoteException implements Exception {
  const PricingRemoteException({required this.type, this.statusCode, this.apiCode, this.message});

  final PricingFailureType type;
  final int? statusCode;
  final String? apiCode;
  final String? message;

  @override
  String toString() => 'PricingRemoteException($type, statusCode=$statusCode, apiCode=$apiCode)';
}

PricingFailureType pricingFailureType(Object error) {
  if (error is PricingRemoteException) return error.type;
  if (error is TimeoutException) return PricingFailureType.network;
  if (error is FormatException) return PricingFailureType.invalidJson;
  if (error is DioException) {
    return _failureTypeForStatus(error.response?.statusCode);
  }
  return PricingFailureType.unknown;
}

PricingFailureType _failureTypeForStatus(int? statusCode) {
  if (statusCode == 401) return PricingFailureType.unauthorized;
  if (statusCode == 403) return PricingFailureType.forbidden;
  if (statusCode == 429) return PricingFailureType.rateLimited;
  if (statusCode != null && statusCode >= 500) return PricingFailureType.serverUnavailable;
  return PricingFailureType.unknown;
}

PricingData legacyBundledPricingData() {
  const plans = [
    PricingPlan(
      planId: 1,
      code: '1',
      months: 1,
      name: '1 month',
      currency: 'RUB',
      baseAmountMinor: 15000,
      discountAmountMinor: 0,
      finalAmountMinor: 15000,
      personalized: false,
      appliedRule: null,
      bundledFallback: true,
    ),
    PricingPlan(
      planId: 2,
      code: '3',
      months: 3,
      name: '3 months',
      currency: 'RUB',
      baseAmountMinor: 40000,
      discountAmountMinor: 0,
      finalAmountMinor: 40000,
      personalized: false,
      appliedRule: null,
      bundledFallback: true,
    ),
    PricingPlan(
      planId: 3,
      code: '6',
      months: 6,
      name: '6 months',
      currency: 'RUB',
      baseAmountMinor: 70000,
      discountAmountMinor: 0,
      finalAmountMinor: 70000,
      personalized: false,
      appliedRule: null,
      bundledFallback: true,
    ),
    PricingPlan(
      planId: 4,
      code: '12',
      months: 12,
      name: '12 months',
      currency: 'RUB',
      baseAmountMinor: 120000,
      discountAmountMinor: 0,
      finalAmountMinor: 120000,
      personalized: false,
      appliedRule: null,
      bundledFallback: true,
    ),
  ];

  // Deprecated bundled catalog: display-only emergency fallback when both
  // server pricing and local cache are unavailable. Never use as payment truth.
  return const PricingData(plans: plans, serverTime: null);
}
