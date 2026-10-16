import 'package:device_info_plus/device_info_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/utils/platform_utils.dart';

final androidWatchProvider = FutureProvider<bool>((ref) async {
  if (!PlatformUtils.isAndroid) return false;
  try {
    final info = await DeviceInfoPlugin().androidInfo.timeout(const Duration(seconds: 5));
    return info.systemFeatures.contains('android.hardware.type.watch');
  } catch (_) {
    return false;
  }
});
