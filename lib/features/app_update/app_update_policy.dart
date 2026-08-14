import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/utils/utils.dart';

/// App-version update checks are intentionally disabled on Apple platforms.
///
/// Keep this policy separate from profile/subscription updates: those continue
/// to use their own update services on every supported platform.
final appUpdateChecksEnabledProvider = Provider<bool>((ref) => !PlatformUtils.isApple);
