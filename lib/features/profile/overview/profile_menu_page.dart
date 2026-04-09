import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProfileMenuPage extends HookConsumerWidget {
  const ProfileMenuPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final sections = <({String title, IconData icon})>[
      (title: t.pages.profileDetails.menu.inviteFriend, icon: Icons.person_add_alt_rounded),
      (title: t.pages.profileDetails.menu.news, icon: Icons.newspaper_rounded),
      (title: t.pages.profileDetails.menu.paymentHistory, icon: Icons.history_rounded),
      (title: t.pages.profileDetails.menu.community, icon: Icons.groups_rounded),
      (title: t.pages.profileDetails.menu.support, icon: Icons.support_agent_rounded),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(t.pages.profileDetails.title.toUpperCase())),
      body: CustomMultiChildLayout(
        delegate: _ProfileMenuLayoutDelegate(),
        children: [
          LayoutId(
            id: _ProfileMenuSlot.actions,
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final section = sections[index];
                return _ProfileMenuSection(title: section.title, icon: section.icon);
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum _ProfileMenuSlot { actions }

class _ProfileMenuLayoutDelegate extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    const contentTop = 0.0;
    final contentWidth = size.width;

    if (hasChild(_ProfileMenuSlot.actions)) {
      final remainingHeight = size.height > contentTop ? size.height - contentTop : 0.0;
      layoutChild(_ProfileMenuSlot.actions, BoxConstraints.tightFor(width: contentWidth, height: remainingHeight));
      positionChild(_ProfileMenuSlot.actions, Offset.zero);
    }
  }

  @override
  bool shouldRelayout(covariant _ProfileMenuLayoutDelegate oldDelegate) => false;
}

class _ProfileMenuSection extends StatelessWidget {
  const _ProfileMenuSection({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () {},
    );
  }
}
