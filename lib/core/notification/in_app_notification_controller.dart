import 'package:flutter/material.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:toastification/toastification.dart';

part 'in_app_notification_controller.g.dart';

@Riverpod(keepAlive: true)
InAppNotificationController inAppNotificationController(Ref ref) {
  return InAppNotificationController();
}

enum NotificationType { info, error, success }

class InAppNotificationController with AppLogger {
  ToastificationItem? _show(
    String message, {
    NotificationType type = NotificationType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    try {
      toastification.dismissAll();
      return toastification.show(
        title: Text(message),
        type: type._toastificationType,
        alignment: AlignmentDirectional.bottomStart,
        autoCloseDuration: duration,
        style: ToastificationStyle.fillColored,
        pauseOnHover: true,
        showProgressBar: false,
        dragToClose: true,
        closeOnClick: true,
        closeButtonShowType: CloseButtonShowType.onHover,
      );
    } catch (error, stackTrace) {
      final errorText = error.toString();
      final isToastificationBootstrapIssue =
          errorText.contains("Toastification is not initialized") ||
          errorText.contains("ToastificationOverlayState") ||
          errorText.contains("ToastificationWrapper");
      if (isToastificationBootstrapIssue) {
        loggy.warning("toastification is not initialized yet, skipping toast", error, stackTrace);
        return null;
      }
      rethrow;
    }
  }

  ToastificationItem? showErrorToast(String message) =>
      _show(message, type: NotificationType.error, duration: const Duration(seconds: 5));

  ToastificationItem? showSuccessToast(String message) => _show(message, type: NotificationType.success);

  ToastificationItem? showInfoToast(String message, {Duration duration = const Duration(seconds: 3)}) =>
      _show(message, duration: duration);

  ToastificationItem? showRemoteNotificationFallback({
    required String title,
    required String body,
    required String? actionUrl,
    VoidCallback? onTap,
  }) {
    try {
      toastification.dismissAll();
      return toastification.showCustom(
        alignment: AlignmentDirectional.bottomStart,
        autoCloseDuration: const Duration(seconds: 12),
        builder: (context, item) => _RemoteNotificationFallbackToast(
          item: item,
          title: title,
          body: body,
          hasAction: actionUrl != null && actionUrl.trim().isNotEmpty,
          onTap: onTap,
        ),
      );
    } catch (error, stackTrace) {
      if (_isToastificationBootstrapIssue(error)) {
        loggy.warning("toastification is not initialized yet, skipping remote fallback toast", error, stackTrace);
        return null;
      }
      rethrow;
    }
  }

  bool _isToastificationBootstrapIssue(Object error) {
    final errorText = error.toString();
    return errorText.contains("Toastification is not initialized") ||
        errorText.contains("ToastificationOverlayState") ||
        errorText.contains("ToastificationWrapper");
  }
}

extension NotificationTypeX on NotificationType {
  ToastificationType get _toastificationType => switch (this) {
    NotificationType.success => ToastificationType.success,
    NotificationType.error => ToastificationType.error,
    NotificationType.info => ToastificationType.info,
  };
}

class _RemoteNotificationFallbackToast extends StatelessWidget {
  const _RemoteNotificationFallbackToast({
    required this.item,
    required this.title,
    required this.body,
    required this.hasAction,
    required this.onTap,
  });

  final ToastificationItem item;
  final String title;
  final String body;
  final bool hasAction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final backgroundColor = Color.alphaBlend(scheme.primary.withValues(alpha: isDark ? .10 : .08), scheme.surface);
    final borderColor = scheme.primary.withValues(alpha: isDark ? .55 : .42);

    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: backgroundColor,
          elevation: isDark ? 0 : 6,
          shadowColor: Colors.black.withValues(alpha: .14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: borderColor),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              onTap?.call();
              toastification.dismiss(item);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: isDark ? .18 : .14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.notifications_active_rounded, color: scheme.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _RemoteNotificationFallbackBody(body: body, hasAction: hasAction),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
                    onPressed: () => toastification.dismiss(item),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RemoteNotificationFallbackBody extends StatelessWidget {
  const _RemoteNotificationFallbackBody({required this.body, required this.hasAction});

  final String body;
  final bool hasAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          body,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (hasAction) ...[
          const SizedBox(height: 8),
          Text(
            'Нажмите, чтобы открыть',
            style: textTheme.labelMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
          ),
        ],
      ],
    );
  }
}
