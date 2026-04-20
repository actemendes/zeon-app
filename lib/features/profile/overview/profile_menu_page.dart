import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/data/profile_name_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

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
    final profile = switch (ref.watch(activeProfileProvider)) {
      AsyncData(value: final profile?) => profile,
      _ => null,
    };
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };
    final remainingDays = _resolveUiRemainingDays(subInfo);
    final sections = <({String title, IconData icon, IconData trailingIcon, VoidCallback? onTap})>[
      if (remainingDays > 0)
        (
          title: t.pages.profileDetails.menu.bindAccount,
          icon: Icons.link_rounded,
          trailingIcon: Icons.chevron_right_rounded,
          onTap: () => context.pushNamed('profileLinkAccount'),
        ),
      (
        title: t.pages.profileDetails.menu.community,
        icon: Icons.groups_rounded,
        trailingIcon: Icons.open_in_new,
        onTap: () {
          unawaited(launchUrl(_communityUri, mode: LaunchMode.externalApplication));
        },
      ),
      (
        title: t.pages.profileDetails.menu.support,
        icon: Icons.support_agent_rounded,
        trailingIcon: Icons.open_in_new,
        onTap: () {
          unawaited(launchUrl(_supportUri, mode: LaunchMode.externalApplication));
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(t.pages.profileDetails.title.toUpperCase())),
      body: CustomMultiChildLayout(
        delegate: _ProfileMenuLayoutDelegate(),
        children: [
          LayoutId(id: _ProfileMenuSlot.summary, child: const _ProfileSummaryBlock()),
          LayoutId(
            id: _ProfileMenuSlot.actions,
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final section = sections[index];
                return _ProfileMenuSection(
                  title: section.title,
                  icon: section.icon,
                  trailingIcon: section.trailingIcon,
                  onTap: section.onTap,
                );
              },
            ),
          ),
          LayoutId(id: _ProfileMenuSlot.cta, child: const _ProfileMenuCtaPanel()),
        ],
      ),
    );
  }
}

enum _ProfileMenuSlot { summary, actions, cta }

class _ProfileMenuLayoutDelegate extends MultiChildLayoutDelegate {
  static const _horizontalPadding = 16.0;
  static const _topPadding = 12.0;
  static const _bottomPadding = 16.0;
  static const _sectionSpacing = 12.0;

  @override
  void performLayout(Size size) {
    var contentTop = 0.0;
    var contentBottom = size.height;

    if (hasChild(_ProfileMenuSlot.summary)) {
      final summaryWidth = (size.width - (_horizontalPadding * 2)).clamp(0.0, size.width);
      layoutChild(
        _ProfileMenuSlot.summary,
        BoxConstraints.tightFor(width: summaryWidth, height: _ProfileSummaryBlock.height),
      );
      positionChild(_ProfileMenuSlot.summary, const Offset(_horizontalPadding, _topPadding));
      contentTop = _topPadding + _ProfileSummaryBlock.height + _sectionSpacing;
    }

    if (hasChild(_ProfileMenuSlot.cta)) {
      final ctaWidth = (size.width - (_horizontalPadding * 2)).clamp(0.0, size.width);
      layoutChild(_ProfileMenuSlot.cta, BoxConstraints.tightFor(width: ctaWidth, height: _ProfileMenuCtaPanel.height));
      final desiredTop = size.height - _bottomPadding - _ProfileMenuCtaPanel.height;
      final ctaTop = desiredTop < contentTop ? contentTop : desiredTop;
      positionChild(_ProfileMenuSlot.cta, Offset(_horizontalPadding, ctaTop));
      contentBottom = ctaTop - _sectionSpacing;
    }

    if (hasChild(_ProfileMenuSlot.actions)) {
      final remainingHeight = contentBottom > contentTop ? contentBottom - contentTop : 0.0;
      layoutChild(_ProfileMenuSlot.actions, BoxConstraints.tightFor(width: size.width, height: remainingHeight));
      positionChild(_ProfileMenuSlot.actions, Offset(0, contentTop));
    }
  }

  @override
  bool shouldRelayout(covariant _ProfileMenuLayoutDelegate oldDelegate) => false;
}

class _ProfileMenuCtaPanel extends HookConsumerWidget {
  const _ProfileMenuCtaPanel();

  static const double height = _ProfileSummaryBlock.height;
  static const _backgroundAsset = 'assets/images/1x/cta-background.png';
  static const _textHorizontalPadding = 20.0;
  static const _arrowSize = 24.0;
  static const _arrowVisualScale = 1.18;

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
    final arrowColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);
    final titleColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          image: const DecorationImage(image: AssetImage(_backgroundAsset), fit: BoxFit.cover),
        ),
        child: InkWell(
          onTap: () => context.pushNamed('profilePayment'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _textHorizontalPadding),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: titleColor,
                      ),
                    ),
                  ),
                ),
                SizedBox.square(
                  dimension: _arrowSize,
                  child: Center(
                    child: Transform.scale(
                      scale: _arrowVisualScale,
                      child: Icon(Icons.arrow_outward, size: _arrowSize, color: arrowColor),
                    ),
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

class _ProfileSummaryBlock extends HookConsumerWidget {
  const _ProfileSummaryBlock();

  static const double height = 65;
  static const double _rightSegmentWidth = 65;
  static const double _textHorizontalPadding = 20;
  static const double _textVerticalPadding = 12;
  static const double _avatarSize = 36;
  static const double _avatarGap = 20;
  static const double _crownPadding = 18;
  static const double _crownSize = 29;

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
    final isPremiumActive = subInfo != null && !subInfo.isExpired && subInfo.ratio < 1 && effectiveDays > 0;
    final profileName = rawProfileName.isNotEmpty ? rawProfileName : t.common.unknown;
    final avatarEmoji = pickAvatarEmoji(avatarSeedName);
    final avatarEmojiAsset = pickAvatarEmojiAsset(avatarSeedName);
    final daysLabel = effectiveDays == 0
        ? t.components.subscriptionInfo.premiumInactive
        : '${t.components.subscriptionInfo.remainingUsage} ${t.common.interval.day(n: effectiveDays)}';
    final surfaceColor = theme.brightness == Brightness.dark ? const Color(0xFF1A1B1F) : const Color(0xFFD6E1E5);
    final subtitleColor = theme.brightness == Brightness.dark ? const Color(0xFF8B8B8B) : const Color(0xFF969696);
    final crownColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3A444D);
    final inactiveBackgroundColor = theme.brightness == Brightness.dark
        ? const Color(0xFF2E3136)
        : const Color(0xFFE4ECCB);

    return Container(
      height: height,
      decoration: BoxDecoration(color: surfaceColor, borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _textHorizontalPadding, vertical: _textVerticalPadding),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: _avatarSize,
                    child: Image.asset(
                      avatarEmojiAsset,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          FittedBox(child: Text(avatarEmoji, textAlign: TextAlign.center)),
                    ),
                  ),
                  const SizedBox(width: _avatarGap),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          daysLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'Montserrat',
                            fontWeight: FontWeight.w500,
                            color: subtitleColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Container(
          //   width: _rightSegmentWidth,
          //   height: height,
          //   decoration: BoxDecoration(
          //     gradient: isPremiumActive ? const LinearGradient(colors: [Color(0xFFBFDD71), Color(0xFF3CE74F)]) : null,
          //     color: isPremiumActive ? null : inactiveBackgroundColor,
          //     borderRadius: BorderRadius.circular(16),
          //   ),
          //   padding: const EdgeInsets.all(_crownPadding),
          //   child: _ProfileCrownIcon(size: _crownSize, color: crownColor),
          // ),
        ],
      ),
    );
  }
}

class _ProfileCrownIcon extends StatelessWidget {
  const _ProfileCrownIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ProfileCrownPainter(color)),
    );
  }
}

class _ProfileCrownPainter extends CustomPainter {
  const _ProfileCrownPainter(this.color);

  static const _viewBox = 31.15;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _viewBox;
    final dx = (size.width - (_viewBox * scale)) / 2;
    final dy = (size.height - (_viewBox * scale)) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final crownPath = Path()
      ..moveTo(1, 30.15)
      ..lineTo(30.15, 30.15)
      ..moveTo(1, 1)
      ..lineTo(1, 23.9)
      ..lineTo(30.15, 23.9)
      ..lineTo(30.15, 1)
      ..lineTo(22.86, 9.33)
      ..lineTo(15.57, 1)
      ..lineTo(8.28, 9.33)
      ..close();

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas.drawPath(crownPath, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ProfileCrownPainter oldDelegate) => oldDelegate.color != color;
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
    return ListTile(leading: Icon(icon), title: Text(title), trailing: Icon(trailingIcon), onTap: onTap ?? () {});
  }
}
