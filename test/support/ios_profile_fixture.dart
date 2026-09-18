import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/db/db.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/notification/app_notice.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:zeon/features/per_app_proxy/data/managed_application_routing.dart';
import 'package:zeon/features/profile/add/add_profile_modal.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/data/profile_data_mapper.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/data/profile_data_source.dart';
import 'package:zeon/features/profile/data/profile_parser.dart';
import 'package:zeon/features/profile/data/profile_path_resolver.dart';
import 'package:zeon/features/profile/data/profile_repository.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/model/profile_failure.dart';
import 'package:zeon/features/profile/notifier/profile_notifier.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set_sync.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';

const _url = 'https://zeon.example.invalid/lab.json';
const _config = '{"outbounds":[{"type":"direct","tag":"fixture-direct"}]}';

// Real form, notifier, parser, repository, encrypted file and SQLite database.
// Only external services, native validation and the keychain are substituted.
Future<ProfileEntity> importIosLabProfile(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'haptic_feedback': false});
  FlutterSecureStorage.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('zeon-sim-import-')))!;
  final databaseFile = File('${root.path}/profiles.sqlite');
  final database = Db(NativeDatabase(databaseFile));
  final source = ProfileDao(database);
  final paths = ProfilePathResolver(Directory('${root.path}/work'), Directory('${root.path}/temp'));
  final store = ProfileConfigStore(pathResolver: paths, preferences: preferences);
  final client = _FixtureDownload();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => preferences),
      translationsProvider.overrideWith((ref) => TranslationsRu()),
      profileDataSourceProvider.overrideWithValue(source),
      mobileBootstrapImportServiceProvider.overrideWithValue(_NoAccountBootstrap()),
      inAppNotificationControllerProvider.overrideWithValue(_SilentNotice()),
      profileRepositoryProvider.overrideWith(
        (ref) => _FixtureRepository(
          profileDataSource: source,
          profilePathResolver: paths,
          singbox: _NoNativeCore(),
          configOptionRepository: ConfigOptionRepository(
            preferences: preferences,
            getConfigOptions: () => throw StateError('Simulator native validation is substituted'),
          ),
          profileParser: ProfileParser(ref: ref, httpClient: client),
          profileConfigStore: store,
          managedRuleSetSyncService: _NoRuleSync(),
          managedApplicationSyncService: _NoApplicationSync(),
        ),
      ),
    ],
  );
  var databaseClosed = false;
  try {
    await tester.runAsync(() => store.init());
    await container.read(sharedPreferencesProvider.future);
    await container.read(translationsProvider.future);
    await container.read(profileRepositoryProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SafeArea(child: SingleChildScrollView(child: AddProfileManual())),
          ),
        ),
      ),
    );
    await tester.pump();
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), 'Simulator import');
    await tester.enterText(fields.at(1), 'not-a-url');
    final add = find.widgetWithText(FilledButton, TranslationsRu().common.add);
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pump();
    expect(find.text(TranslationsRu().pages.profileDetails.form.invalidUrl), findsOneWidget);
    expect(client.requests, isEmpty);
    await tester.enterText(fields.at(1), _url);
    await tester.ensureVisible(add);
    await tester.tap(add);
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      if (!container.read(addProfileNotifierProvider).isLoading) break;
    }
    expect(container.read(addProfileNotifierProvider), const AsyncData<Unit?>(unit));
    expect(client.requests, [_url]);
    final active = await tester.runAsync(source.getActiveProfile);
    expect(active, isNotNull);
    expect(active!.name, 'Simulator import');
    expect(active.url, _url);
    expect(await tester.runAsync(() => store.read(active.id)), _config);
    expect(
      (await tester.runAsync(() => paths.encryptedFile(active.id).readAsString()))!,
      isNot(contains('fixture-direct')),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.runAsync(database.close);
    databaseClosed = true;
    final reopened = Db(NativeDatabase(databaseFile));
    try {
      final persisted = await tester.runAsync(() => ProfileDao(reopened).getActiveProfile());
      expect(persisted?.id, active.id);
      return persisted!.toEntity();
    } finally {
      await tester.runAsync(reopened.close);
    }
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.runAsync(() async {
      if (!databaseClosed) await database.close();
      await root.delete(recursive: true);
    });
  }
}

class _FixtureRepository extends ProfileRepositoryImpl {
  _FixtureRepository({
    required super.profileDataSource,
    required super.profilePathResolver,
    required super.singbox,
    required super.configOptionRepository,
    required super.profileParser,
    required super.profileConfigStore,
    required super.managedRuleSetSyncService,
    required super.managedApplicationSyncService,
  });

  @override
  TaskEither<ProfileFailure, String> validateConfig(String tempPath, String? profileOverride, bool debug) =>
      TaskEither.tryCatch(() => File(tempPath).readAsString(), ProfileFailure.unexpected);
}

class _FixtureDownload extends DioHttpClient {
  _FixtureDownload() : super(timeout: const Duration(seconds: 1), userAgent: 'ZEON-Simulator-lab', debug: false);
  final requests = <String>[];
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
    if (url != _url) throw StateError('Unexpected Simulator fixture request');
    requests.add(url);
    await File(path).writeAsString(_config);
    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      headers: Headers(),
    );
  }
}

class _NoNativeCore implements ZeonCoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Native core must not run during Simulator import');
}

class _NoRuleSync implements ManagedRuleSetSyncService {
  @override
  Future<ManagedRuleSetSyncResult> sync({bool force = false, String reason = 'scheduled'}) async =>
      ManagedRuleSetSyncResult.skipped;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoApplicationSync implements ManagedApplicationSyncService {
  @override
  Future<ManagedApplicationSyncResult> sync({bool force = false, String reason = 'scheduled'}) async =>
      ManagedApplicationSyncResult.skipped;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoAccountBootstrap implements MobileBootstrapImportService {
  @override
  Future<void> pruneToSingleProfileIfManaged() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Account bootstrap must not run in Simulator import');
}

class _SilentNotice extends InAppNotificationController {
  @override
  AppNoticeHandle? showSuccessToast(String message) => null;
}
