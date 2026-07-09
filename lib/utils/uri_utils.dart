import 'dart:io';

import 'package:loggy/loggy.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zeon/utils/custom_loggers.dart';

abstract class UriUtils {
  static final loggy = Loggy<InfraLogger>("UriUtils");

  static Future<bool> tryShareOrLaunchFile(Uri uri, {Uri? fileOrDir}) {
    if (Platform.isWindows || Platform.isLinux) {
      return tryLaunch(fileOrDir ?? uri);
    }
    return tryShareFile(uri);
  }

  static Future<bool> tryLaunch(Uri uri) async {
    final description = _describeUri(uri);
    try {
      loggy.debug("launching [$description]");
      final launchedExternal = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launchedExternal) return true;

      final launchedDefault = await launchUrl(uri);
      if (launchedDefault) return true;

      if (_isWebUri(uri)) {
        final launchedInApp = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
        if (launchedInApp) return true;
      }
      if (Platform.isWindows && _isWebUri(uri)) {
        return _tryLaunchWindowsWebUri(uri);
      }
      loggy.warning("can't launch [$description]");
      return false;
    } catch (e, stackTrace) {
      if (Platform.isWindows && _isWebUri(uri)) {
        final launched = await _tryLaunchWindowsWebUri(uri);
        if (launched) return true;
      }
      loggy.warning("error launching [$description]", e, stackTrace);
      return false;
    }
  }

  static Future<bool> tryShareFile(Uri uri, {String? mimeType}) async {
    try {
      loggy.debug("sharing [$uri]");
      final file = XFile(uri.path, mimeType: mimeType);
      final result = await Share.shareXFiles([file]);
      loggy.debug("share result: ${result.raw}");
      return result.status == ShareResultStatus.success;
    } catch (e, stackTrace) {
      loggy.warning("error sharing file [$uri]", e, stackTrace);
      return false;
    }
  }

  static bool _isWebUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme == "http" || scheme == "https";
  }

  static Future<bool> _tryLaunchWindowsWebUri(Uri uri) async {
    final description = _describeUri(uri);
    try {
      loggy.debug("launching via explorer.exe [$description]");
      await Process.start("explorer.exe", [uri.toString()], mode: ProcessStartMode.detached);
      return true;
    } catch (e, stackTrace) {
      loggy.warning("error launching via explorer.exe [$description]", e, stackTrace);
      return false;
    }
  }

  static String _describeUri(Uri uri) {
    final scheme = uri.scheme.isEmpty ? "-" : uri.scheme;
    final host = uri.host.isEmpty ? "-" : uri.host;
    final path = uri.path.isEmpty ? "/" : uri.path;
    final query = uri.hasQuery ? " queryKeys=${uri.queryParameters.keys.join(",")}" : "";
    return "scheme=$scheme host=$host path=$path$query";
  }
}
