import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/notification/app_notice.dart';
import 'package:zeon/core/router/dialog/widgets/custom_alert_dialog.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';

part 'in_app_notification_controller.g.dart';

@Riverpod(keepAlive: true)
InAppNotificationController inAppNotificationController(Ref ref) {
  return InAppNotificationController();
}

class InAppNotificationController {
  InAppNotificationController({AppNoticeController? notices}) : _notices = notices ?? appNoticeController;

  final AppNoticeController _notices;

  AppNoticeHandle? showToast(
    String message, {
    AppNoticeKind kind = AppNoticeKind.info,
    Duration duration = const Duration(seconds: 3),
    String? diagnosticText,
    BuildContext? context,
    IconData? icon,
  }) => _notices.show(
    AppNotice(
      title: message,
      kind: kind,
      identity: ('local', kind, message, diagnosticText),
      duration: duration,
      icon: icon,
      onTap: diagnosticText == null ? null : () => _showDiagnosticDialog(message, diagnosticText, context),
    ),
  );

  AppNoticeHandle? showErrorToast(String message, {String? diagnosticText}) => showToast(
    message,
    kind: AppNoticeKind.error,
    duration: const Duration(seconds: 5),
    diagnosticText: diagnosticText ?? message,
  );

  AppNoticeHandle? showSuccessToast(String message) => showToast(message, kind: AppNoticeKind.success);

  AppNoticeHandle? showInfoToast(String message, {Duration duration = const Duration(seconds: 3)}) =>
      showToast(message, duration: duration);

  AppNoticeHandle? showRemoteNotificationFallback({
    required String title,
    required String body,
    required String? actionUrl,
    String? notificationId,
    VoidCallback? onTap,
  }) => _notices.show(
    AppNotice(
      title: title,
      body: body,
      kind: AppNoticeKind.remote,
      identity: ('remote', notificationId ?? (title, body, actionUrl)),
      duration: const Duration(seconds: 12),
      hasAction: actionUrl != null && actionUrl.trim().isNotEmpty,
      onTap: onTap,
    ),
  );

  void _showDiagnosticDialog(String title, String diagnosticText, BuildContext? sourceContext) {
    final context = rootNavKey.currentContext ?? sourceContext;
    if (context == null || !context.mounted) return;
    Navigator.of(context, rootNavigator: true).push<void>(
      DialogRoute(
        context: context,
        builder: (context) => CustomAlertDialog(title: title, message: diagnosticText, diagnosticText: diagnosticText),
      ),
    );
  }
}
