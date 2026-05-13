import 'dart:convert';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/utils/utils.dart';

abstract interface class AppUpdateRepository {
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  });
}

class AppUpdateRepositoryImpl with ExceptionHandler, InfraLogger implements AppUpdateRepository {
  AppUpdateRepositoryImpl({required this.httpClient});

  final DioHttpClient httpClient;

  @override
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  }) {
    return exceptionHandler(() async {
      if (!release.allowCustomUpdateChecker) {
        throw Exception("custom update checkers are not supported");
      }
      final response = await httpClient.get<dynamic>(Constants.githubReleasesApiUrl);
      if (response.statusCode != 200 || response.data == null) {
        loggy.warning("failed to fetch latest version info");
        return left(const AppUpdateFailure.unexpected());
      }

      final dynamic raw = response.data;
      final List<dynamic> releaseList;
      if (raw is List) {
        releaseList = raw;
      } else if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is! List) {
          loggy.warning("invalid releases payload type after decode: [${decoded.runtimeType}]");
          return left(const AppUpdateFailure.unexpected());
        }
        releaseList = decoded;
      } else {
        loggy.warning("invalid releases payload type: [${raw.runtimeType}]");
        return left(const AppUpdateFailure.unexpected());
      }

      if (releaseList.isEmpty) {
        loggy.warning("no releases found in repository");
        return left(const AppUpdateFailure.unexpected());
      }

      final releases = releaseList.map((e) => GithubReleaseParser.parse(e as Map<String, dynamic>)).toList();
      late RemoteVersionEntity latest;
      if (includePreReleases) {
        latest = releases.first;
      } else {
        latest = releases.firstWhere((e) => !e.preRelease, orElse: () => releases.first);
      }
      return right(latest);
    }, AppUpdateFailure.unexpected);
  }
}
