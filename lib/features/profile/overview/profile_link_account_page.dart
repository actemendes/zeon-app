import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProfileLinkAccountPage extends HookConsumerWidget {
  const ProfileLinkAccountPage({super.key});

  static const _maxContentWidth = 920.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final profileName = switch (ref.watch(activeProfileProvider)) {
      AsyncData(value: final profile?) => profile.name,
      _ => '',
    };

    final now = useState(DateTime.now());
    final devices = useState<List<_LinkedDevice>>([
      _LinkedDevice(id: 'current', name: t.pages.profileDetails.linkAccount.currentDevice),
      const _LinkedDevice(id: 'iphone', name: 'iPhone 14 Pro'),
      const _LinkedDevice(id: 'macbook', name: 'MacBook Air'),
    ]);

    useEffect(() {
      final timer = Timer.periodic(const Duration(minutes: 1), (_) {
        now.value = DateTime.now();
      });
      return timer.cancel;
    }, const []);

    final code = _generateHourlyCode(profileName, now.value);
    final nextHour = DateTime(now.value.year, now.value.month, now.value.day, now.value.hour + 1);
    final minutesUntilRefresh = nextHour.difference(now.value).inMinutes.clamp(0, 59);
    final codePanelColor = theme.brightness == Brightness.dark ? const Color(0xFF1A1B1F) : const Color(0xFFD6E1E5);
    final codePanelBorderColor = theme.brightness == Brightness.dark
        ? const Color(0xFF333333)
        : const Color(0xFFC3CDD2);
    final codeTextColor = theme.colorScheme.onSurface;
    final subtitleColor = theme.brightness == Brightness.dark ? const Color(0xFF8B8B8B) : const Color(0xFF707780);
    final dangerBackground = theme.brightness == Brightness.dark ? const Color(0xFF291718) : const Color(0xFFFFEAEA);
    final dangerForeground = theme.brightness == Brightness.dark ? const Color(0xFFFFB4AB) : const Color(0xFF8E1A1A);

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
                child: Column(
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
                        _formatCode(code),
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
              ),
              const SizedBox(height: 22),
              Text(
                t.pages.profileDetails.linkAccount.connectedDevices,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              if (devices.value.isEmpty)
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    t.pages.profileDetails.linkAccount.noDevices,
                    style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'Montserrat', fontWeight: FontWeight.w500),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: devices.value.length,
                    separatorBuilder: (context, index) =>
                        Divider(height: 1, color: theme.colorScheme.onSurface.withValues(alpha: .1)),
                    itemBuilder: (context, index) {
                      final device = devices.value[index];
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                        leading: Icon(
                          device.id == 'current' ? Icons.phone_android_rounded : Icons.devices_rounded,
                          size: 20,
                        ),
                        title: Text(
                          device.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'Montserrat',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: t.pages.profileDetails.linkAccount.removeDevice,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () async {
                            final confirmed = await _showYesNoDialog(
                              context: context,
                              title: t.pages.profileDetails.linkAccount.removeDeviceTitle,
                              message: t.pages.profileDetails.linkAccount.removeDeviceMessage(name: device.name),
                              yesLabel: t.pages.profileDetails.linkAccount.yes,
                              noLabel: t.pages.profileDetails.linkAccount.no,
                            );
                            if (!context.mounted || !confirmed) return;
                            devices.value = devices.value.where((e) => e.id != device.id).toList(growable: false);
                          },
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  foregroundColor: dangerForeground,
                  backgroundColor: dangerBackground,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  final confirmed = await _showYesNoDialog(
                    context: context,
                    title: t.pages.profileDetails.linkAccount.deleteAccountTitle,
                    message: t.pages.profileDetails.linkAccount.deleteAccountMessage,
                    yesLabel: t.pages.profileDetails.linkAccount.yes,
                    noLabel: t.pages.profileDetails.linkAccount.no,
                  );
                  if (!context.mounted || !confirmed) return;
                  await ref.read(Preferences.introCompleted.notifier).update(false);
                  if (!context.mounted) return;
                  context.goNamed('intro');
                },
                icon: const Icon(Icons.delete_forever_rounded),
                label: Text(
                  t.pages.profileDetails.linkAccount.deleteAccount,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: dangerForeground,
                    fontFamily: 'Unbounded',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _showYesNoDialog({
    required BuildContext context,
    required String title,
    required String message,
    required String yesLabel,
    required String noLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(noLabel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(yesLabel)),
        ],
      ),
    );
    return result ?? false;
  }

  String _generateHourlyCode(String seed, DateTime dateTime) {
    final hourlySeed = '${dateTime.year}${dateTime.month}${dateTime.day}${dateTime.hour}|$seed';
    var hash = 0x811c9dc5;
    for (final cu in hourlySeed.codeUnits) {
      hash ^= cu;
      hash = (hash + (hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24)) & 0x7fffffff;
    }
    final value = 100000 + (hash % 900000);
    return value.toString().padLeft(6, '0');
  }

  String _formatCode(String code) => '${code.substring(0, 3)} ${code.substring(3)}';
}

class _LinkedDevice {
  const _LinkedDevice({required this.id, required this.name});

  final String id;
  final String name;
}
