import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

const avatarEmojis = [
  '\u{1F98A}', // 🦊
  '\u{1F43A}', // 🐺
  '\u{1F43C}', // 🐼
  '\u{1F42F}', // 🐯
  '\u{1F981}', // 🦁
  '\u{1F438}', // 🐸
  '\u{1F419}', // 🐙
  '\u{1F989}', // 🦉
  '\u{1F435}', // 🐵
  '\u{1F428}', // 🐨
  '\u{1F427}', // 🐧
  '\u{1F433}', // 🐳
  '\u{1F984}', // 🦄
  '\u{1F41D}', // 🐝
  '\u{1F98B}', // 🦋
  '\u{1F422}', // 🐢
  '\u{1F996}', // 🦖
  '\u{1F432}', // 🐲
  '\u{1F34B}', // 🍋
  '\u{1F340}', // 🍀
  '\u{1F319}', // 🌙
  '\u{2B50}', // ⭐
  '\u{26A1}', // ⚡
  '\u{1F525}', // 🔥
  '\u{1F9CA}', // 🧊
  '\u{1F30A}', // 🌊
  '\u{1F33F}', // 🌿
  '\u{1F349}', // 🍉
  '\u{1F355}', // 🍕
  '\u{2615}', // ☕
  '\u{1F3A7}', // 🎧
  '\u{1F579}\u{FE0F}', // 🕹️
  '\u{1F4BE}', // 💾
  '\u{1F9E9}', // 🧩
  '\u{1F527}', // 🔧
  '\u{1F6F0}\u{FE0F}', // 🛰️
];

int fnv1a32(String input) {
  var h = 0x811c9dc5;
  for (final cu in input.codeUnits) {
    h ^= cu;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

String pickAvatarEmoji(String? profileName) {
  final raw = (profileName ?? '').trim();
  final normalized = raw.isEmpty ? 'user' : raw;
  final stable = normalized.toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_').replaceAll(RegExp('_+'), '_');
  final hash = fnv1a32('v1|$stable');
  return avatarEmojis[hash % avatarEmojis.length];
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
    final remainingDays = subInfo == null ? 0 : (subInfo.remaining.inDays < 0 ? 0 : subInfo.remaining.inDays);

    final sections = <({String title, IconData icon, IconData trailingIcon, VoidCallback? onTap})>[
      if (remainingDays > 0)
        (
          title: t.pages.profileDetails.menu.bindAccount,
          icon: Icons.link_rounded,
          trailingIcon: Icons.chevron_right_rounded,
          onTap: null,
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
  static const _bottomPadding = 12.0;
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
    final remainingDays = subInfo == null ? 0 : (subInfo.remaining.inDays < 0 ? 0 : subInfo.remaining.inDays);
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
  static const _premiumInactiveLabel =
      "\u043f\u0440\u0435\u043c\u0438\u0443\u043c \u043d\u0435 \u0430\u043a\u0442\u0438\u0432\u0435\u043d";

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

    final rawProfileName = (profile?.name ?? '').trim();
    final normalizedDays = subInfo == null ? 0 : (subInfo.remaining.inDays < 0 ? 0 : subInfo.remaining.inDays);
    final isPremiumActive = subInfo != null && !subInfo.isExpired && subInfo.ratio < 1 && normalizedDays > 0;
    final profileName = rawProfileName.isNotEmpty ? rawProfileName : t.common.unknown;
    final avatarEmoji = pickAvatarEmoji(rawProfileName);
    final daysLabel = normalizedDays == 0
        ? _premiumInactiveLabel
        : t.components.subscriptionInfo.remainingDuration(duration: normalizedDays);
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
                    child: FittedBox(child: Text(avatarEmoji, textAlign: TextAlign.center)),
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
          Container(
            width: _rightSegmentWidth,
            height: height,
            decoration: BoxDecoration(
              gradient: isPremiumActive ? const LinearGradient(colors: [Color(0xFFBFDD71), Color(0xFF3CE74F)]) : null,
              color: isPremiumActive ? null : inactiveBackgroundColor,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(_crownPadding),
            child: _ProfileCrownIcon(size: _crownSize, color: crownColor),
          ),
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
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Icon(trailingIcon),
      onTap: onTap ?? () {},
    );
  }
}
