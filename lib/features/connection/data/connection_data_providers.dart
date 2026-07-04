import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/features/connection/data/connection_repository.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/settings/data/config_option_data_providers.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

part 'connection_data_providers.g.dart';

@Riverpod(keepAlive: true)
ConnectionRepository connectionRepository(Ref ref) {
  return ConnectionRepositoryImpl(
    ref: ref,
    directories: ref.watch(appDirectoriesProvider).requireValue,
    configOptionRepository: ref.watch(configOptionRepositoryProvider),
    singbox: ref.watch(zeonCoreServiceProvider),
    profileConfigStore: ref.watch(profileConfigStoreProvider),
  );
}
