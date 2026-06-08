import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/pricing/data/pricing_repository.dart';
import 'package:hiddify/features/pricing/model/pricing_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('ignores personalized cache after user change', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPreferencesPricingCacheStore(prefs);
    final data = _data([_plan('3', 3, 25000, personalized: true)]);

    await store.writePersonalized(data, DateTime.utc(2026, 6, 8), currentUserId: 10);

    expect(await store.readPersonalized(currentUserId: 11), isNull);
    expect(prefs.getString('pricing_personal_cache_body'), isNull);
  });

  test('moves from public prices to personalized prices when JWT appears', () async {
    final remote = _Remote(
      publicData: _data([_plan('3', 3, 40000)]),
      personalizedData: _data([_plan('3', 3, 25000, personalized: true)]),
    );
    final auth = _Auth(resolvedJwt: 'jwt');
    final repository = PricingRepository(
      remoteDataSource: remote,
      cacheStore: _MemoryCache(),
      deviceAuth: auth,
      currentUserId: () => 7,
      now: () => DateTime.utc(2026, 6, 8),
    );

    final publicCatalog = await repository.refreshPricing();
    auth.peekJwt = 'jwt';
    final personalizedCatalog = await repository.refreshPricing();

    expect(publicCatalog.source, PricingCatalogSource.publicRemote);
    expect(personalizedCatalog.source, PricingCatalogSource.personalizedRemote);
    expect(personalizedCatalog.data.plans.single.finalAmountMinor, 25000);
  });

  test('keeps offline cache available when refresh fails', () async {
    final cache = _MemoryCache();
    await cache.writePublic(_data([_plan('1', 1, 15000)]), DateTime.utc(2026, 6, 8));
    final repository = PricingRepository(
      remoteDataSource: _Remote(publicError: const PricingRemoteException(type: PricingFailureType.serverUnavailable)),
      cacheStore: cache,
      deviceAuth: _Auth(),
      currentUserId: () => null,
    );

    final cached = await repository.getCachedPricing();

    expect(cached!.source, PricingCatalogSource.publicCache);
    expect(cached.data.plans.single.code, '1');
  });

  test('retries personalized request once after JWT refresh on 401', () async {
    final remote = _Remote(
      personalizedData: _data([_plan('12', 12, 120000, personalized: true)]),
      personalizedErrors: [const PricingRemoteException(type: PricingFailureType.unauthorized, statusCode: 401)],
    );
    final auth = _Auth(peekJwt: 'old', resolvedJwt: 'old', refreshedJwt: 'new');
    final repository = PricingRepository(
      remoteDataSource: remote,
      cacheStore: _MemoryCache(),
      deviceAuth: auth,
      currentUserId: () => 4,
    );

    final catalog = await repository.refreshPricing();

    expect(remote.personalizedTokens, ['old', 'new']);
    expect(auth.forceRefreshCalls, 1);
    expect(catalog.data.plans.single.code, '12');
  });

  test('maps 401, 403, 429 and 5xx errors', () {
    expect(
      pricingFailureType(const PricingRemoteException(type: PricingFailureType.unauthorized, statusCode: 401)),
      PricingFailureType.unauthorized,
    );
    expect(
      pricingFailureType(const PricingRemoteException(type: PricingFailureType.forbidden, statusCode: 403)),
      PricingFailureType.forbidden,
    );
    expect(
      pricingFailureType(const PricingRemoteException(type: PricingFailureType.rateLimited, statusCode: 429)),
      PricingFailureType.rateLimited,
    );
    expect(
      pricingFailureType(const PricingRemoteException(type: PricingFailureType.serverUnavailable, statusCode: 502)),
      PricingFailureType.serverUnavailable,
    );
  });

  test('selects plans by code instead of array position', () {
    final plans = [_plan('12', 12, 120000), _plan('1', 1, 15000)];
    final selected = plans.firstWhere((plan) => plan.code == '1');

    expect(selected.months, 1);
  });
}

PricingData _data(List<PricingPlan> plans) => PricingData(plans: plans, serverTime: DateTime.utc(2026, 6, 8));

PricingPlan _plan(String code, int months, int amount, {bool personalized = false}) {
  return PricingPlan(
    planId: months,
    code: code,
    months: months,
    name: '$months months',
    currency: 'RUB',
    baseAmountMinor: amount,
    discountAmountMinor: 0,
    finalAmountMinor: amount,
    personalized: personalized,
    appliedRule: null,
  );
}

class _Auth implements PricingDeviceAuth {
  _Auth({this.peekJwt = '', this.resolvedJwt = '', this.refreshedJwt});

  String peekJwt;
  String resolvedJwt;
  String? refreshedJwt;
  int forceRefreshCalls = 0;

  @override
  String peekCachedDeviceJwt() => peekJwt;

  @override
  Future<String> resolveDeviceJwt({bool forceRefresh = false}) async {
    if (forceRefresh) {
      forceRefreshCalls += 1;
      return refreshedJwt ?? resolvedJwt;
    }
    return resolvedJwt;
  }
}

class _Remote implements PricingRemoteDataSource {
  _Remote({this.publicData, this.personalizedData, this.publicError, List<Object>? personalizedErrors})
    : personalizedErrors = personalizedErrors ?? [];

  final PricingData? publicData;
  final PricingData? personalizedData;
  final Object? publicError;
  final List<Object> personalizedErrors;
  final personalizedTokens = <String>[];

  @override
  Future<PricingData> getPublicPricing() async {
    final error = publicError;
    if (error != null) throw error;
    return publicData ?? _data([_plan('1', 1, 15000)]);
  }

  @override
  Future<PricingData> getPersonalizedPricing(String deviceJwt, {bool forceRefresh = false}) async {
    personalizedTokens.add(deviceJwt);
    if (personalizedErrors.isNotEmpty) throw personalizedErrors.removeAt(0);
    return personalizedData ?? _data([_plan('1', 1, 15000, personalized: true)]);
  }
}

class _MemoryCache implements PricingCacheStore {
  CachedPricing? publicCache;
  CachedPricing? personalCache;

  @override
  Future<void> clearPersonalized() async => personalCache = null;

  @override
  Future<CachedPricing?> readPersonalized({required int? currentUserId}) async {
    final cache = personalCache;
    if (cache == null) return null;
    if (cache.userId != currentUserId) {
      personalCache = null;
      return null;
    }
    return cache;
  }

  @override
  Future<CachedPricing?> readPublic() async => publicCache;

  @override
  Future<void> writePersonalized(PricingData data, DateTime fetchedAt, {required int currentUserId}) async {
    personalCache = CachedPricing(data: data, fetchedAt: fetchedAt, userId: currentUserId);
  }

  @override
  Future<void> writePublic(PricingData data, DateTime fetchedAt) async {
    publicCache = CachedPricing(data: data, fetchedAt: fetchedAt);
  }
}
