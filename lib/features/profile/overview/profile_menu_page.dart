import 'package:flutter/material.dart';

class ProfileMenuPage extends StatelessWidget {
  const ProfileMenuPage({super.key});

  static const title = '\u041F\u0440\u043E\u0444\u0438\u043B\u044C';
  static const _sections = <({String title, IconData icon})>[
    (
      title: '\u041F\u0440\u0438\u0433\u043B\u0430\u0441\u0438\u0442\u044C \u0434\u0440\u0443\u0433\u0430',
      icon: Icons.person_add_alt_rounded,
    ),
    (title: '\u041D\u043E\u0432\u043E\u0441\u0442\u0438', icon: Icons.newspaper_rounded),
    (
      title: '\u0418\u0441\u0442\u043E\u0440\u0438\u044F \u043F\u043B\u0430\u0442\u0435\u0436\u0435\u0439',
      icon: Icons.history_rounded,
    ),
    (title: '\u0421\u043E\u043E\u0431\u0449\u0435\u0441\u0442\u0432\u043E', icon: Icons.groups_rounded),
    (title: '\u041F\u043E\u0434\u0434\u0435\u0440\u0436\u043A\u0430', icon: Icons.support_agent_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: CustomMultiChildLayout(
        delegate: _ProfileMenuLayoutDelegate(),
        children: [
          LayoutId(
            id: _ProfileMenuSlot.actions,
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _sections.length,
              itemBuilder: (context, index) {
                final section = _sections[index];
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
