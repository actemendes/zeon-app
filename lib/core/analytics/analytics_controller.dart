import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'analytics_controller.g.dart';

const String enableAnalyticsPrefKey = "enable_analytics";

@Riverpod(keepAlive: true)
class AnalyticsController extends _$AnalyticsController with AppLogger {
  @override
  Future<bool> build() async {
    await _preferences.setBool(enableAnalyticsPrefKey, false);
    return false;
  }

  SharedPreferences get _preferences => ref.read(sharedPreferencesProvider).requireValue;

  Future<void> enableAnalytics() async {
    loggy.debug("analytics disabled by app configuration");
    await _preferences.setBool(enableAnalyticsPrefKey, false);
    state = const AsyncData(false);
  }

  Future<void> disableAnalytics() async {
    loggy.debug("analytics disabled");
    await _preferences.setBool(enableAnalyticsPrefKey, false);
    state = const AsyncData(false);
  }
}
