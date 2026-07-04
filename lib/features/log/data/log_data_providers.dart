import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/features/log/data/log_path_resolver.dart';
import 'package:zeon/features/log/data/log_repository.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'log_data_providers.g.dart';

@Riverpod(keepAlive: true)
Future<LogRepository> logRepository(LogRepositoryRef ref) async {
  final repo = LogRepositoryImpl(
    singbox: ref.watch(zeonCoreServiceProvider),
    logPathResolver: ref.watch(logPathResolverProvider),
  );
  await repo.init().getOrElse((l) => throw l).run();
  return repo;
}

@Riverpod(keepAlive: true)
LogPathResolver logPathResolver(LogPathResolverRef ref) {
  return LogPathResolver(ref.watch(appDirectoriesProvider).requireValue.workingDir);
}
