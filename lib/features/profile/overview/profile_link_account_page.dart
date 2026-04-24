import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProfileLinkAccountPage extends ConsumerWidget {
  const ProfileLinkAccountPage({super.key});

  static const _maxContentWidth = 920.0;
  static const _accountLink = 'https://zeon-vps.link/open/649669380';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final notification = ref.read(inAppNotificationControllerProvider);
    final linkPanelBorderColor = theme.brightness == Brightness.dark
        ? const Color(0xFF333333)
        : const Color(0xFFC3CDD2);
    final subtitleColor = theme.brightness == Brightness.dark ? const Color(0xFF8B8B8B) : const Color(0xFF5B6670);

    return Scaffold(
      appBar: AppBar(title: Text(t.pages.profileDetails.linkAccount.title.toUpperCase())),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxContentWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t.pages.profileDetails.linkAccount.linkHint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w500,
                    height: 1.38,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: linkPanelBorderColor),
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.pages.profileDetails.linkAccount.linkLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          color: subtitleColor,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        _accountLink,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          await Clipboard.setData(const ClipboardData(text: _accountLink));
                          notification.showSuccessToast(t.pages.profileDetails.linkAccount.copySuccess);
                        },
                        icon: const Icon(Icons.content_copy_rounded),
                        label: Text(t.pages.profileDetails.linkAccount.copyLink),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await ref.read(Preferences.introCompleted.notifier).update(false);
                    if (!context.mounted) return;
                    context.goNamed('intro');
                  },
                  icon: const Icon(Icons.switch_account_rounded),
                  label: Text(
                    t.pages.profileDetails.linkAccount.changeAccount,
                    style: theme.textTheme.titleSmall?.copyWith(fontFamily: 'Unbounded', fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
