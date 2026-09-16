import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/db/provider/db_providers.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/http_client/http_client_provider.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/home_tips/home_tip_provider.dart';
import 'package:zeon/features/per_app_proxy/data/managed_application_routing.dart';
import 'package:zeon/features/profile/data/profile_config_store.dart';
import 'package:zeon/features/profile/data/profile_data_source.dart';
import 'package:zeon/features/profile/data/profile_parser.dart';
import 'package:zeon/features/profile/data/profile_path_resolver.dart';
import 'package:zeon/features/profile/data/profile_repository.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set_sync.dart';
import 'package:zeon/features/settings/data/config_option_data_providers.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

part 'profile_data_providers.g.dart';

@Riverpod(keepAlive: true)
Future<ProfileRepository> profileRepository(Ref ref) async {
  final repo = ProfileRepositoryImpl(
    profileDataSource: ref.watch(profileDataSourceProvider),
    profilePathResolver: ref.watch(profilePathResolverProvider),
    singbox: ref.watch(zeonCoreServiceProvider),
    configOptionRepository: ref.watch(configOptionRepositoryProvider),
    profileParser: ref.watch(profileParserProvider),
    profileConfigStore: ref.watch(profileConfigStoreProvider),
    managedRuleSetSyncService: ref.watch(managedRuleSetSyncServiceProvider),
    managedApplicationSyncService: ref.watch(managedApplicationSyncServiceProvider),
    refreshHomeTip: () => ref.read(homeTipProvider.notifier).refresh(),
  );
  await repo.init().getOrElse((l) => throw l).run();
  return repo;
}

@Riverpod(keepAlive: true)
ProfileDataSource profileDataSource(Ref ref) {
  return ProtectedProfileDataSource(
    delegate: ProfileDao(ref.watch(dbProvider)),
    configStore: ref.watch(profileConfigStoreProvider),
    // debug_platform_override controls preview layout only. Web profiles live
    // in IndexedDB and must not be routed through the native file-backed
    // protection layer when the preview emulates Windows.
    enabled: !kIsWeb && (PlatformUtils.isApple || PlatformUtils.isAndroid || PlatformUtils.isWindows),
  );
}

@Riverpod(keepAlive: true)
ProfilePathResolver profilePathResolver(Ref ref) {
  final directories = ref.watch(appDirectoriesProvider).requireValue;
  return ProfilePathResolver(directories.workingDir, directories.tempDir);
}

@Riverpod(keepAlive: true)
ProfileConfigStore profileConfigStore(Ref ref) {
  return ProfileConfigStore(
    pathResolver: ref.watch(profilePathResolverProvider),
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
  );
}

@Riverpod(keepAlive: true)
ProfileParser profileParser(Ref ref) {
  return ProfileParser(ref: ref, httpClient: ref.watch(httpClientProvider));
}
