import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/router/dialog/widgets/custom_alert_dialog.dart';
import 'package:hiddify/core/router/go_router/go_router_notifier.dart';
import 'package:toastification/toastification.dart';

enum AlertType {
  info,
  error,
  success;

  ToastificationType get _toastificationType => switch (this) {
    success => ToastificationType.success,
    error => ToastificationType.error,
    info => ToastificationType.info,
  };
}

class CustomToast extends StatelessWidget {
  const CustomToast(
    this.message, {
    this.type = AlertType.info,
    this.icon,
    this.duration = const Duration(seconds: 3),
    this.diagnosticText,
  });

  const CustomToast.error(this.message, {this.duration = const Duration(seconds: 5), this.diagnosticText})
    : type = AlertType.error,
      icon = FluentIcons.error_circle_24_regular;

  const CustomToast.success(this.message, {this.duration = const Duration(seconds: 3)})
    : type = AlertType.success,
      icon = FluentIcons.checkmark_24_regular,
      diagnosticText = null;

  final String message;
  final AlertType type;
  final IconData? icon;
  final Duration duration;
  final String? diagnosticText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (type) {
      AlertType.info => null,
      AlertType.error => scheme.error,
      AlertType.success => scheme.tertiary,
    };

    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        color: Theme.of(context).colorScheme.surface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, color: color), const SizedBox(width: 8)],
          Flexible(child: Text(message)),
        ],
      ),
    );
  }

  void show(BuildContext context) {
    toastification.show(
      context: context,
      title: Text(message),
      type: type._toastificationType,
      alignment: Alignment.bottomLeft,
      autoCloseDuration: duration,
      style: ToastificationStyle.fillColored,
      pauseOnHover: true,
      showProgressBar: false,
      dragToClose: true,
      closeOnClick: true,
      closeButtonShowType: CloseButtonShowType.onHover,
      callbacks: ToastificationCallbacks(
        onTap: type != AlertType.error
            ? null
            : (item) {
                toastification.dismiss(item);
                final context = rootNavKey.currentContext;
                if (context == null) return;
                final details = diagnosticText ?? message;
                Navigator.of(context, rootNavigator: true).push<void>(
                  DialogRoute(
                    context: context,
                    builder: (context) => CustomAlertDialog(title: message, message: details, diagnosticText: details),
                  ),
                );
              },
      ),
    );
  }
}
