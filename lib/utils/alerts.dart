import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:zeon/core/notification/app_notice.dart';
import 'package:zeon/core/notification/app_notice_host.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';

enum AlertType {
  info,
  error,
  success;

  AppNoticeKind get _noticeKind => switch (this) {
    success => AppNoticeKind.success,
    error => AppNoticeKind.error,
    info => AppNoticeKind.info,
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
  Widget build(BuildContext context) => AppNoticeCard(
    entry: AppNoticeEntry(0, AppNotice(title: message, kind: type._noticeKind, identity: message, icon: icon)),
    onTap: () {},
    onClose: () {},
  );

  void show(BuildContext context) {
    InAppNotificationController().showToast(
      message,
      kind: type._noticeKind,
      duration: duration,
      diagnosticText: type == AlertType.error ? diagnosticText ?? message : null,
      context: context,
      icon: icon,
    );
  }
}
