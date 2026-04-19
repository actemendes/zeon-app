import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/mobile/data/mobile_bind_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProfileLinkAccountPage extends HookConsumerWidget {
  const ProfileLinkAccountPage({super.key});

  static const _maxContentWidth = 920.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final service = ref.read(mobileBindServiceProvider);
    final notification = ref.read(inAppNotificationControllerProvider);

    final now = useState(DateTime.now().toUtc());
    final bindSession = useState<BindCreateResult?>(null);
    final status = useState<String>("loading");
    final error = useState<String?>(null);
    final targetDevice = useState<String?>(null);
    final wsConnection = useRef<BindWsConnection?>(null);

    Future<void> bootstrap() async {
      error.value = null;
      status.value = "loading";
      bindSession.value = null;

      try {
        final created = await service.createSession();
        bindSession.value = created;
        status.value = "pending";
        try {
          final conn = await service.connectSessionEvents(created.bindSessionId);
          wsConnection.value = conn;
          if (conn != null) {
            conn.events.listen((event) {
              if (!context.mounted) return;
              switch (event.event) {
                case "bind_confirmed":
                  status.value = "confirmed";
                  final platform = event.targetPlatform?.trim();
                  final mask = event.targetDeviceMask?.trim();
                  targetDevice.value = [platform, mask].whereType<String>().where((e) => e.isNotEmpty).join(" ");
                  notification.showSuccessToast(t.common.done);
                case "bind_expired":
                  status.value = "expired";
                case "bind_cancelled":
                  status.value = "cancelled";
              }
            });
          }
        } catch (_) {
          // WebSocket is optional; status polling continues to work.
        }
      } on MobileBindException catch (e) {
        error.value = e.code;
        status.value = "error";
      } catch (_) {
        error.value = t.errors.unexpected;
        status.value = "error";
      }
    }

    useEffect(() {
      bootstrap();
      final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        now.value = DateTime.now().toUtc();
      });
      final poller = Timer.periodic(const Duration(seconds: 10), (_) async {
        final session = bindSession.value;
        if (session == null) return;
        if (status.value != "pending") return;
        try {
          final current = await service.getStatus(session.bindSessionId);
          status.value = current.status;
        } catch (_) {
          // Keep pending state, websocket may still deliver updates.
        }
      });
      return () {
        ticker.cancel();
        poller.cancel();
        final session = bindSession.value;
        final currentStatus = status.value;
        if (session != null && currentStatus == "pending") {
          unawaited(service.cancelSession(session.bindSessionId));
        }
        unawaited(wsConnection.value?.close() ?? Future<void>.value());
      };
    }, const []);

    final session = bindSession.value;
    final expiresAt = session?.expiresAt;
    final remainingSeconds = expiresAt == null ? 0 : expiresAt.difference(now.value).inSeconds.clamp(0, 360000);
    final minutesUntilRefresh = (remainingSeconds / 60).ceil().clamp(0, 99);
    final codePanelColor = theme.brightness == Brightness.dark ? const Color(0xFF1A1B1F) : const Color(0xFFD6E1E5);
    final codePanelBorderColor = theme.brightness == Brightness.dark
        ? const Color(0xFF333333)
        : const Color(0xFFC3CDD2);
    final subtitleColor = theme.brightness == Brightness.dark ? const Color(0xFF8B8B8B) : const Color(0xFF707780);
    final codeTextColor = theme.colorScheme.onSurface;

    return Scaffold(
      appBar: AppBar(title: Text(t.pages.profileDetails.linkAccount.title.toUpperCase())),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Text(
                t.pages.profileDetails.linkAccount.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w500,
                  height: 1.38,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: codePanelColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: codePanelBorderColor),
                ),
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                child: switch (status.value) {
                  "loading" => const Center(
                    child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()),
                  ),
                  "error" => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _friendlyError(error.value),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(onPressed: bootstrap, child: const Text("Повторить")),
                    ],
                  ),
                  _ => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.pages.profileDetails.linkAccount.codeLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          color: subtitleColor,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _formatCode(session?.bindCode ?? "------"),
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontFamily: 'Unbounded',
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2.6,
                            color: codeTextColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t.pages.profileDetails.linkAccount.updatesInMinutes(n: minutesUntilRefresh),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w500,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                },
              ),
              const SizedBox(height: 20),
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(14),
                child: Text(
                  _statusText(status.value, targetDevice.value),
                  style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: () async {
                  await ref.read(Preferences.introCompleted.notifier).update(false);
                  if (!context.mounted) return;
                  context.goNamed('intro');
                },
                icon: const Icon(Icons.delete_forever_rounded),
                label: Text(
                  t.pages.profileDetails.linkAccount.deleteAccount,
                  style: theme.textTheme.titleSmall?.copyWith(fontFamily: 'Unbounded', fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCode(String code) {
    if (code.length < 6) return code;
    return '${code.substring(0, 3)} ${code.substring(3)}';
  }

  String _statusText(String status, String? targetDevice) {
    switch (status) {
      case "pending":
        return "Ожидание подтверждения кода на втором устройстве";
      case "confirmed":
        final suffix = (targetDevice == null || targetDevice.isEmpty) ? "" : ": $targetDevice";
        return "Привязка подтверждена$suffix";
      case "expired":
        return "Код истек, обновите страницу";
      case "cancelled":
        return "Сессия привязки отменена";
      case "loading":
        return "Создаем сессию привязки...";
      default:
        return "Ошибка привязки";
    }
  }

  String _friendlyError(String? code) {
    switch ((code ?? "").trim()) {
      case "jwt_expired":
      case "unauthorized":
      case "missing_claims":
      case "invalid_signature":
      case "invalid_jwt":
      case "device_id_missing":
      case "user_id_missing":
        return "Сессия привязки истекла. Нажмите «Повторить».";
      case "bind_not_configured":
        return "Сервис привязки временно недоступен. Попробуйте позже.";
      case "device_already_bound":
        return "Это устройство уже привязано к аккаунту.";
      case "network_connectionError":
      case "network_connectionTimeout":
      case "network_socket":
      case "network_tls":
        return "Нет соединения с сервером. Проверьте интернет и повторите.";
      default:
        return code?.isNotEmpty == true ? code! : "Ошибка привязки";
    }
  }
}
