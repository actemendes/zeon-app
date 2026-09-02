import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/db/db.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/data/profile_data_source.dart';
import 'package:zeon/features/profile/data/profile_parser.dart';
import 'package:zeon/features/profile/data/profile_path_resolver.dart';
import 'package:zeon/features/profile/data/profile_repository.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/model/profile_sort_enum.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set_sync.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

void main() {
  const legacyUrl = 'https://130.49.151.173/subscription/fixture';
  const canonicalUrl = 'https://api.zeon-vps.online/subscription/fixture';
  const cachedConfig = '{"cached":true}';

  late Directory root;
  late SharedPreferences preferences;
  late ProviderContainer container;
  late _MemoryProfileDataSource dataSource;
  late _MemoryProfileConfigStore configStore;

  Future<ProfileRepositoryImpl> createRepository({required bool failDownload, bool invalidMetadata = false}) async {
    final pathResolver = ProfilePathResolver(Directory('${root.path}/work'), Directory('${root.path}/temp'));
    final client = _RecordingDioHttpClient(failDownload: failDownload, invalidMetadata: invalidMetadata);
    final parserProvider = Provider<ProfileParser>((ref) => ProfileParser(ref: ref, httpClient: client));
    final coreProvider = Provider<ZeonCoreService>((ref) => ZeonCoreService(ref, coreInterface: CoreInterface()));
    final parser = container.read(parserProvider);
    final core = container.read(coreProvider);
    configStore = _MemoryProfileConfigStore(pathResolver: pathResolver, preferences: preferences)
      ..contents['profile-id'] = cachedConfig;

    return ProfileRepositoryImpl(
      profileDataSource: dataSource,
      profilePathResolver: pathResolver,
      singbox: core,
      configOptionRepository: ConfigOptionRepository(
        preferences: preferences,
        getConfigOptions: () => throw StateError('config options are not used when validation is disabled'),
      ),
      profileParser: parser,
      profileConfigStore: configStore,
      managedRuleSetSyncService: ManagedRuleSetSyncService(
        remoteDataSource: const _UnusedRuleSetRemoteDataSource(),
        store: ManagedRuleSetStore(directory: Directory('${root.path}/rules')),
        preferences: preferences,
      ),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zeon-legacy-profile-migration-');
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)]);
    await container.read(sharedPreferencesProvider.future);
    dataSource = _MemoryProfileDataSource(
      ProfileEntry(
        id: 'profile-id',
        type: ProfileType.remote,
        active: true,
        name: 'cached profile',
        url: legacyUrl,
        lastUpdate: DateTime.utc(2026),
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await root.delete(recursive: true);
  });

  test('successful refresh requests and persists the canonical domain', () async {
    final repository = await createRepository(failDownload: false);
    final result = await repository
        .upsertRemote(legacyUrl, validateConfigOnImport: false, syncManagedRuleSets: false, disableRetry: true)
        .run();

    expect(result.isRight(), isTrue);
    expect(dataSource.current.url, canonicalUrl);
    expect(dataSource.current.active, isTrue);
    expect(dataSource.editCalls, 1);
    expect(configStore.contents['profile-id'], isNot(cachedConfig));
    expect(configStore.lastWrittenProfileId, 'profile-id');
    expect(_RecordingDioHttpClient.lastCreated.requests, [canonicalUrl]);
  });

  test('failed canonical request leaves the persisted URL and cached config intact', () async {
    final repository = await createRepository(failDownload: true);
    final result = await repository
        .upsertRemote(legacyUrl, validateConfigOnImport: false, syncManagedRuleSets: false, disableRetry: true)
        .run();

    expect(result.isLeft(), isTrue);
    expect(_RecordingDioHttpClient.lastCreated.requests, [canonicalUrl]);
    expect(dataSource.current.url, legacyUrl);
    expect(dataSource.current.active, isTrue);
    expect(dataSource.editCalls, 0);
    expect(configStore.contents['profile-id'], cachedConfig);
    expect(configStore.lastWrittenProfileId, isNull);
  });

  test('post-download profile parsing failure does not persist the migration', () async {
    final repository = await createRepository(failDownload: false, invalidMetadata: true);
    final result = await repository
        .upsertRemote(legacyUrl, validateConfigOnImport: false, syncManagedRuleSets: false, disableRetry: true)
        .run();

    expect(result.isLeft(), isTrue);
    expect(_RecordingDioHttpClient.lastCreated.requests, [canonicalUrl]);
    expect(dataSource.current.url, legacyUrl);
    expect(dataSource.current.active, isTrue);
    expect(dataSource.editCalls, 0);
    expect(configStore.contents['profile-id'], cachedConfig);
  });

  test('canonical URL stays unchanged and canonicalization is independent of proxyOnly', () async {
    dataSource.current = dataSource.current.copyWith(url: const Value(canonicalUrl));
    final repository = await createRepository(failDownload: false);
    final result = await repository
        .upsertRemote(
          canonicalUrl,
          proxyOnly: true,
          validateConfigOnImport: false,
          syncManagedRuleSets: false,
          disableRetry: true,
        )
        .run();

    expect(result.isRight(), isTrue);
    expect(_RecordingDioHttpClient.lastCreated.requests, [canonicalUrl]);
    expect(_RecordingDioHttpClient.lastCreated.proxyOnlyValues, [true]);
    expect(dataSource.current.url, canonicalUrl);
  });
}

class _RecordingDioHttpClient extends DioHttpClient {
  _RecordingDioHttpClient({required this.failDownload, required this.invalidMetadata})
    : super(timeout: const Duration(seconds: 1), userAgent: 'ZEON-test', debug: false, isWindows: false) {
    lastCreated = this;
  }

  static late _RecordingDioHttpClient lastCreated;
  final bool failDownload;
  final bool invalidMetadata;
  final List<String> requests = <String>[];
  final List<bool> proxyOnlyValues = <bool>[];

  @override
  Future<Response<dynamic>> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
    bool proxyOnly = false,
    bool directOnly = false,
    bool disableRetry = false,
    String? operation,
  }) async {
    requests.add(url);
    proxyOnlyValues.add(proxyOnly);
    final request = RequestOptions(path: url);
    if (failDownload) {
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
        error: const SocketException('offline'),
      );
    }
    await File(path).writeAsString('{"outbounds":[]}');
    return Response<dynamic>(
      requestOptions: request,
      statusCode: HttpStatus.ok,
      headers: invalidMetadata
          ? Headers.fromMap(<String, List<String>>{
              'profile-update-interval': <String>['not-an-int'],
            })
          : Headers(),
    );
  }
}

class _MemoryProfileDataSource implements ProfileDataSource {
  _MemoryProfileDataSource(this.current);

  ProfileEntry current;
  int editCalls = 0;

  @override
  Future<ProfileEntry?> getById(String id) async => current.id == id ? current : null;

  @override
  Future<ProfileEntry?> getActiveProfile() async => current.active ? current : null;

  @override
  Future<ProfileEntry?> getByUrl(String url) async => current.url?.contains(url) == true ? current : null;

  @override
  Future<ProfileEntry?> getByName(String name) async => current.name == name ? current : null;

  @override
  Stream<ProfileEntry?> watchActiveProfile() => Stream<ProfileEntry?>.value(current);

  @override
  Stream<int> watchProfilesCount() => Stream<int>.value(1);

  @override
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode}) =>
      Stream<List<ProfileEntry>>.value(<ProfileEntry>[current]);

  @override
  Future<void> migrateSensitiveFields() async {}

  @override
  Future<void> insert(ProfileEntriesCompanion entry) => throw UnimplementedError();

  @override
  Future<void> edit(String id, ProfileEntriesCompanion entry) async {
    expect(id, current.id);
    editCalls++;
    current = current.copyWithCompanion(entry);
  }

  @override
  Future<void> deleteById(String id, bool isActive) => throw UnimplementedError();
}

class _MemoryProfileConfigStore extends ProfileConfigStore {
  _MemoryProfileConfigStore({required super.pathResolver, required super.preferences});

  final Map<String, String> contents = <String, String>{};
  String? lastWrittenProfileId;

  @override
  Future<void> write(String profileId, String plaintext) async {
    lastWrittenProfileId = profileId;
    contents[profileId] = plaintext;
  }

  @override
  Future<String> read(String profileId) async => contents[profileId] ?? (throw StateError('missing config'));

  @override
  Future<void> refreshRuntimeConnectionFileIfExists(String profileId, {String? content}) async {}
}

class _UnusedRuleSetRemoteDataSource implements ManagedRuleSetRemoteDataSource {
  const _UnusedRuleSetRemoteDataSource();

  @override
  Future<ManagedRuleSetFetchResult> fetch({String? eTag}) => throw UnimplementedError();
}
