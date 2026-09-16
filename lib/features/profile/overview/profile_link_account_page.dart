import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/utils/link_parsers.dart';

class ProfileLinkAccountPage extends ConsumerWidget {
  const ProfileLinkAccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final translations = ref.watch(translationsProvider).requireValue;
    final t = translations.pages.profileDetails.linkAccount;
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final notification = ref.read(inAppNotificationControllerProvider);
    final profile = switch (ref.watch(activeProfileProvider)) {
      AsyncData(value: final profile?) => profile,
      _ => null,
    };
    final accountLink = switch (profile) {
      RemoteProfileEntity(:final url) when url.trim().isNotEmpty => LinkParser.toPublicOpenProfileLink(url),
      _ => '',
    };
    final canCopy = accountLink.isNotEmpty;
    return Scaffold(
      key: const ValueKey(UiNames.screenProfileLinkAccount),
      appBar: AppBar(
        centerTitle: false,
        toolbarHeight: 76,
        leading: IconButton(
          tooltip: 'Назад',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          t.title.toUpperCase(),
          maxLines: 2,
          style: theme.textTheme.titleMedium?.copyWith(fontSize: 17, height: 1.4, fontWeight: FontWeight.w600),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    t.description,
                    key: const ValueKey(UiNames.textProfileLinkHint),
                    style: TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.65,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    key: const ValueKey(UiNames.panelProfileLinkAccount),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(20)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.link_rounded, size: 22, color: cs.onSurfaceVariant),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                t.linkLabel,
                                key: const ValueKey(UiNames.textProfileLinkLabel),
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SelectableText(
                          canCopy ? accountLink : '—',
                          key: const ValueKey(UiNames.textProfileLinkValue),
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontSize: 16,
                            height: 1.6,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          key: const ValueKey(UiNames.buttonProfileLinkCopy),
                          onPressed: canCopy
                              ? () async {
                                  await Clipboard.setData(ClipboardData(text: accountLink));
                                  notification.showSuccessToast(translations.common.done);
                                }
                              : null,
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          label: Text(t.copyLink),
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.primary,
                            foregroundColor: cs.onPrimary,
                            minimumSize: const Size(double.infinity, 48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            textStyle: const TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Spacer(),
                  Material(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: const ValueKey(UiNames.buttonProfileLinkChangeAccount),
                      onTap: () async {
                        await ref.read(Preferences.introCompleted.notifier).update(false);
                        if (context.mounted) context.goNamed('intro');
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: [
                            Icon(Icons.switch_account_rounded, size: 22, color: cs.onSurfaceVariant),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                t.deleteAccount,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded, size: 19, color: cs.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
