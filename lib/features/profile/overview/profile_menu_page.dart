import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/profile/data/profile_name_parser.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/profile/overview/external_subscription_account.dart';
import 'package:zeon/features/profile/overview/profiles_notifier.dart';

const _avatarEmojiAssetDir = 'assets/images/emoji/apple/64';
const _debugSeedProfileEnabled = bool.fromEnvironment('debug_seed_profile_enabled');
const _debugSeedProfileName = String.fromEnvironment('debug_seed_profile_name');
const _debugSeedProfileRemainingDays = int.fromEnvironment('debug_seed_profile_remaining_days', defaultValue: -1);

int _resolveUiRemainingDays(SubscriptionInfo? subInfo) {
  if (subInfo == null) return 0;
  final remaining = subInfo.remaining;
  if (remaining.inSeconds <= 0) return 0;
  final days = remaining.inDays;
  return days < 1 ? 1 : days;
}

const _avatarEmojis = <({String emoji, String assetFile})>[
  (emoji: '\u{1F98A}', assetFile: '1f98a.png'),
  (emoji: '\u{1F43A}', assetFile: '1f43a.png'),
  (emoji: '\u{1F43C}', assetFile: '1f43c.png'),
  (emoji: '\u{1F42F}', assetFile: '1f42f.png'),
  (emoji: '\u{1F981}', assetFile: '1f981.png'),
  (emoji: '\u{1F438}', assetFile: '1f438.png'),
  (emoji: '\u{1F419}', assetFile: '1f419.png'),
  (emoji: '\u{1F989}', assetFile: '1f989.png'),
  (emoji: '\u{1F435}', assetFile: '1f435.png'),
  (emoji: '\u{1F428}', assetFile: '1f428.png'),
  (emoji: '\u{1F427}', assetFile: '1f427.png'),
  (emoji: '\u{1F433}', assetFile: '1f433.png'),
  (emoji: '\u{1F984}', assetFile: '1f984.png'),
  (emoji: '\u{1F41D}', assetFile: '1f41d.png'),
  (emoji: '\u{1F98B}', assetFile: '1f98b.png'),
  (emoji: '\u{1F422}', assetFile: '1f422.png'),
  (emoji: '\u{1F996}', assetFile: '1f996.png'),
  (emoji: '\u{1F432}', assetFile: '1f432.png'),
  (emoji: '\u{1F34B}', assetFile: '1f34b.png'),
  (emoji: '\u{1F340}', assetFile: '1f340.png'),
  (emoji: '\u{1F319}', assetFile: '1f319.png'),
  (emoji: '\u{2B50}', assetFile: '2b50.png'),
  (emoji: '\u{26A1}', assetFile: '26a1.png'),
  (emoji: '\u{1F525}', assetFile: '1f525.png'),
  (emoji: '\u{1F9CA}', assetFile: '1f9ca.png'),
  (emoji: '\u{1F30A}', assetFile: '1f30a.png'),
  (emoji: '\u{1F33F}', assetFile: '1f33f.png'),
  (emoji: '\u{1F349}', assetFile: '1f349.png'),
  (emoji: '\u{1F355}', assetFile: '1f355.png'),
  (emoji: '\u{2615}', assetFile: '2615.png'),
  (emoji: '\u{1F3A7}', assetFile: '1f3a7.png'),
  (emoji: '\u{1F579}\u{FE0F}', assetFile: '1f579-fe0f.png'),
  (emoji: '\u{1F4BE}', assetFile: '1f4be.png'),
  (emoji: '\u{1F9E9}', assetFile: '1f9e9.png'),
  (emoji: '\u{1F527}', assetFile: '1f527.png'),
  (emoji: '\u{1F6F0}\u{FE0F}', assetFile: '1f6f0-fe0f.png'),
];

int fnv1a32(String input) {
  var h = 0x811c9dc5;
  for (final cu in input.codeUnits) {
    h ^= cu;
    // JS number multiplication can lose 32-bit precision on web builds.
    // FNV prime 16777619 = 1 + 2 + 16 + 128 + 256 + 16777216.
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) & 0xffffffff;
  }
  return h;
}

String _normalizeAvatarSeed(String? profileName) {
  final source = (profileName ?? '').trim();
  final suffix = source.contains('|') ? source.split('|').last.trim() : source;
  final fallback = suffix.isEmpty ? 'user' : suffix;

  final stable = fallback
      .toLowerCase()
      .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
      .replaceAll(RegExp(r'[\s\-]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  return stable.isEmpty ? 'user' : stable;
}

int _avatarIndex(String? profileName) {
  final stable = _normalizeAvatarSeed(profileName);
  final hash = fnv1a32('v1|$stable');
  return hash % _avatarEmojis.length;
}

String pickAvatarEmoji(String? profileName) {
  return _avatarEmojis[_avatarIndex(profileName)].emoji;
}

String pickAvatarEmojiAsset(String? profileName) {
  final assetFile = _avatarEmojis[_avatarIndex(profileName)].assetFile;
  return '$_avatarEmojiAssetDir/$assetFile';
}

class ProfileMenuPage extends HookConsumerWidget {
  const ProfileMenuPage({super.key});

  static final Uri _communityUri = Uri.parse('https://t.me/zvo_net');
  static final Uri _supportUri = Uri.parse('https://t.me/zvo_net_support_bot');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final profilesCount = ref.watch(profilesNotifierProvider).valueOrNull?.length ?? 0;
    final sections = <({String title, IconData icon, IconData trailingIcon, VoidCallback? onTap})>[
      if (profilesCount > 1)
        (
          title: t.pages.profiles.viewAllProfiles,
          icon: Icons.list_alt_rounded,
          trailingIcon: Icons.chevron_right_rounded,
          onTap: () {
            if (Breakpoint(context).isMobile()) {
              ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview();
            } else {
              context.goNamed('profiles');
            }
          },
        ),
      (
        title: t.pages.profileDetails.menu.bindAccount,
        icon: Icons.link_rounded,
        trailingIcon: Icons.chevron_right_rounded,
        onTap: () => context.pushNamed('profileLinkAccount'),
      ),
      (
        title: t.pages.profileDetails.menu.community,
        icon: Icons.groups_rounded,
        trailingIcon: Icons.arrow_outward_rounded,
        onTap: () {
          unawaited(launchUrl(_communityUri, mode: LaunchMode.externalApplication));
        },
      ),
      (
        title: t.pages.profileDetails.menu.support,
        icon: Icons.support_agent_rounded,
        trailingIcon: Icons.arrow_outward_rounded,
        onTap: () {
          unawaited(launchUrl(_supportUri, mode: LaunchMode.externalApplication));
        },
      ),
    ];

    return Scaffold(
      key: const ValueKey(UiNames.screenProfileMenu),
      appBar: AppBar(centerTitle: false, title: Text(t.pages.profileDetails.title.toUpperCase())),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _ProfileSummaryBlock(),
            const SizedBox(height: 24),
            Material(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 54, right: 18),
                        child: Divider(
                          height: 1,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .09),
                        ),
                      ),
                    _ProfileMenuSection(
                      title: sections[i].title,
                      icon: sections[i].icon,
                      trailingIcon: sections[i].trailingIcon,
                      onTap: sections[i].onTap,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _ProfileMenuCtaPanel(),
          ],
        ),
      ),
    );
  }
}

class _ProfileMenuCtaPanel extends HookConsumerWidget {
  const _ProfileMenuCtaPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final profile = switch (ref.watch(activeProfileProvider)) {
      AsyncData(value: final profile?) => profile,
      _ => null,
    };
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };
    final remainingDays = _resolveUiRemainingDays(subInfo);
    final title = (remainingDays > 0 ? t.pages.profileDetails.cta.renew : t.pages.profileDetails.cta.updatePlan)
        .toUpperCase();
    return Material(
      color: theme.colorScheme.primary,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            unawaited(openExternalSubscriptionAccount(context, ref, profile is RemoteProfileEntity ? profile : null)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.arrow_outward_rounded, size: 22, color: theme.colorScheme.onPrimary),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileSummaryBlock extends HookConsumerWidget {
  const _ProfileSummaryBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final profile = switch (ref.watch(activeProfileProvider)) {
      AsyncData(value: final profile?) => profile,
      _ => null,
    };
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };

    final rawProfileName = parseProfileName(profile?.name).trim();
    final avatarSeedName = (kDebugMode && _debugSeedProfileEnabled && _debugSeedProfileName.trim().isNotEmpty)
        ? _debugSeedProfileName
        : rawProfileName;
    final normalizedDays = _resolveUiRemainingDays(subInfo);
    final effectiveDays = (kDebugMode && _debugSeedProfileEnabled && _debugSeedProfileRemainingDays >= 0)
        ? _debugSeedProfileRemainingDays
        : normalizedDays;
    final profileName = rawProfileName.isNotEmpty ? rawProfileName : t.common.unknown;
    final avatarEmoji = pickAvatarEmoji(avatarSeedName);
    final avatarEmojiAsset = pickAvatarEmojiAsset(avatarSeedName);
    final daysLabel = effectiveDays == 0
        ? t.components.subscriptionInfo.premiumInactive
        : '${t.components.subscriptionInfo.remainingUsage} ${t.common.interval.day(n: effectiveDays)}';
    return Row(
      children: [
        SizedBox.square(
          dimension: 40,
          child: Image.asset(
            avatarEmojiAsset,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => FittedBox(child: Text(avatarEmoji)),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontSize: 19, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      daysLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileMenuSection extends StatelessWidget {
  const _ProfileMenuSection({
    required this.title,
    required this.icon,
    this.trailingIcon = Icons.chevron_right_rounded,
    this.onTap,
  });

  final String title;
  final IconData icon;
  final IconData trailingIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 23),
            const SizedBox(width: 14),
            Expanded(
              child: Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            Icon(trailingIcon, size: 19, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
