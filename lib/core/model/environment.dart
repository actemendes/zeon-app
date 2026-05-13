import 'package:dartx/dartx.dart';

enum Environment {
  prod,
  dev;

  static const sentryDSN = String.fromEnvironment("sentry_dsn");
  // This environment variable is set in the 'windows-release-zip' command
  static const isPortable = bool.fromEnvironment("portable");
}

enum Release {
  general("general"),
  // This environment variable is set in the 'android-release-aab' command
  googlePlay("google-play");

  const Release(this.key);

  final String key;

  bool get allowCustomUpdateChecker => this == general;

  static Release read() =>
      Release.values.firstOrNullWhere((e) => e.key == const String.fromEnvironment("release")) ?? Release.general;
}

enum UpdateChannel {
  stable("stable", includePreReleases: false),
  beta("beta", includePreReleases: true);

  const UpdateChannel(this.key, {required this.includePreReleases});

  final String key;
  final bool includePreReleases;

  static UpdateChannel read() =>
      UpdateChannel.values.firstOrNullWhere((e) => e.key == const String.fromEnvironment("update_channel")) ??
      UpdateChannel.stable;
}
