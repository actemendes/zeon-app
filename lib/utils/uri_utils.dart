import 'dart:io';

import 'package:hiddify/utils/custom_loggers.dart';
import 'package:loggy/loggy.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

abstract class UriUtils {
  static final loggy = Loggy<InfraLogger>("UriUtils");

  static Future<bool> tryShareOrLaunchFile(Uri uri, {Uri? fileOrDir}) async {
    if (Platform.isWindows || Platform.isLinux) {
      return tryLaunch(fileOrDir ?? uri);
    }
    return tryShareFile(uri);
  }

  static Future<bool> tryLaunch(Uri uri) async {
    try {
      loggy.debug("launching [$uri]");
      final launchedExternal = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launchedExternal) return true;

      final launchedDefault = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (launchedDefault) return true;

      if (uri.hasScheme && (uri.scheme == "http" || uri.scheme == "https")) {
        final launchedInApp = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
        if (launchedInApp) return true;
      }
      loggy.warning("can't launch [$uri]");
      return false;
    } catch (e, stackTrace) {
      loggy.warning("error launching [$uri]", e, stackTrace);
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
}
