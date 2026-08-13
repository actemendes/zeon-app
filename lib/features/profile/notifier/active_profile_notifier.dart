import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/features/profile/data/profile_data_mapper.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/utils/utils.dart';

part 'active_profile_notifier.g.dart';

@Riverpod(keepAlive: true)
class ActiveProfile extends _$ActiveProfile with AppLogger {
  @override
  Stream<ProfileEntity?> build() async* {
    loggy.debug("watching active profile");
    final source = ref.watch(profileDataSourceProvider);
    final initial = await source.getActiveProfile();
    final initialEntity = initial?.toEntity();
    yield initialEntity;
    yield* source.watchActiveProfile().map((event) => event?.toEntity()).where((event) => event != initialEntity);
  }
}

// TODO: move to specific feature
@Riverpod(keepAlive: true)
Stream<bool> hasAnyProfile(Ref ref) {
  return ref.watch(profileDataSourceProvider).watchProfilesCount().map((event) => event != 0).distinct();
}
