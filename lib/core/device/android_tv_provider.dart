import 'package:device_info_plus/device_info_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/utils/platform_utils.dart';

/// Use platform features, not screen width: Android tablets keep their layout.
final androidTvProvider = FutureProvider<bool>((ref) async {
  if (!PlatformUtils.isAndroid) return false;
  try {
    final info = await DeviceInfoPlugin().androidInfo.timeout(const Duration(seconds: 1));
    return hasAndroidTvFeatures(info.systemFeatures);
  } catch (_) {
    // An optional presentation hint must never prevent startup.
    return false;
  }
});

bool hasAndroidTvFeatures(Iterable<String> features) =>
    features.contains('android.software.leanback') || features.contains('android.hardware.type.television');
