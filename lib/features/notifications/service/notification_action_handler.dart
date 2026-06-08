import 'package:hiddify/utils/custom_loggers.dart';
import 'package:url_launcher/url_launcher.dart';

class NotificationActionHandler with InfraLogger {
  static const allowedSchemes = {'https', 'zeon'};
  static const maxActionUrlLength = 2048;

  bool isAllowed(String? rawUrl) {
    final uri = parseAllowed(rawUrl);
    return uri != null && _isAllowedUri(uri);
  }

  Uri? parseAllowed(String? rawUrl) {
    final value = rawUrl?.trim();
    if (value == null || value.isEmpty || value.length > maxActionUrlLength) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return null;
    return _isAllowedUri(uri) ? uri : null;
  }

  Future<bool> open(String? rawUrl) async {
    final uri = parseAllowed(rawUrl);
    if (uri == null) return false;
    try {
      return await launchUrl(
        uri,
        mode: uri.scheme == 'https' ? LaunchMode.externalApplication : LaunchMode.platformDefault,
      );
    } catch (e, st) {
      loggy.warning('notification action_url open failed [scheme=${uri.scheme}]', e, st);
      return false;
    }
  }

  bool _isAllowedUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (!allowedSchemes.contains(scheme)) return false;
    if (scheme == 'https') return uri.host.trim().isNotEmpty;
    if (scheme == 'zeon') return uri.host.trim().isNotEmpty || uri.pathSegments.isNotEmpty;
    return false;
  }
}
