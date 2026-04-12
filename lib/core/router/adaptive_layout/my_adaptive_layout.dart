import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/adaptive_layout/shell_route_action.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/core/router/go_router/routing_config_notifier.dart';
import 'package:hiddify/features/stats/widget/side_bar_stats_overview.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class MyAdaptiveLayout extends HookConsumerWidget {
  const MyAdaptiveLayout({
    super.key,
    required this.navigationShell,
    required this.isMobileBreakpoint,
    required this.showProfilesAction,
  });
  // managed by go router(Shell Route)
  final StatefulNavigationShell navigationShell;
  final bool isMobileBreakpoint;
  final bool showProfilesAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final actions = _actions(t, isMobileBreakpoint);
    final actionBranchNames = _actionBranchNames(isMobileBreakpoint);
    final currentBranchName = getNameOfBranch(isMobileBreakpoint, showProfilesAction, navigationShell.currentIndex);
    final selectedBranchName = currentBranchName == 'profiles' ? 'profileMenu' : currentBranchName;
    final selectedActionIndex = actionBranchNames.indexOf(
      selectedBranchName,
    );
    final navSelectedIndex = selectedActionIndex >= 0 ? selectedActionIndex : 0;
    // focus switch management
    final primaryFocusHash = useState<int?>(null);
    final navScopeNode = useFocusScopeNode();
    useEffect(() {
      bool handler(KeyEvent event) {
        final arrows = isMobileBreakpoint ? KeyboardConst.verticalArrows : KeyboardConst.horizontalArrows;
        if (!arrows.contains(event.logicalKey)) return false;
        if (event is KeyDownEvent) {
          primaryFocusHash.value = FocusManager.instance.primaryFocus.hashCode;
        } else {
          // focus node does not change => true.
          if (primaryFocusHash.value == FocusManager.instance.primaryFocus.hashCode) {
            if (branchesScope.values.any((node) => node.hasFocus)) {
              navScopeNode.requestFocus();
            } else if (navScopeNode.hasFocus) {
              branchesScope[getNameOfBranch(isMobileBreakpoint, showProfilesAction, navigationShell.currentIndex)]
                  ?.requestFocus();
            }
          }
        }
        return true;
      }

      HardwareKeyboard.instance.addHandler(handler);
      return () {
        HardwareKeyboard.instance.removeHandler(handler);
      };
    }, [isMobileBreakpoint, showProfilesAction, navigationShell.currentIndex]);
    return Material(
      child: Scaffold(
        body: isMobileBreakpoint
            ? navigationShell
            : Row(
                children: [
                  FocusScope(
                    node: navScopeNode,
                    child: NavigationRail(
                      extended: Breakpoint(context).isDesktop(),
                      destinations: _navRailDests(actions),
                      selectedIndex: navSelectedIndex,
                      onDestinationSelected: (index) => _onTap(index, actionBranchNames),
                      trailing: Breakpoint(context).isDesktop()
                          ? const Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: SizedBox(width: 220, child: SideBarStatsOverview()),
                              ),
                            )
                          : null,
                    ),
                  ),
                  Expanded(child: navigationShell),
                ],
              ),
        bottomNavigationBar: isMobileBreakpoint
            ? FocusScope(
                node: navScopeNode,
                child: NavigationBar(
                  selectedIndex: navSelectedIndex,
                  destinations: _navDests(actions),
                  onDestinationSelected: (index) => _onTap(index, actionBranchNames),
                ),
              )
            : null,
      ),
    );
  }

  // shell route action onTap
  void _onTap(int actionIndex, List<String> actionBranchNames) {
    if (actionIndex < 0 || actionIndex >= actionBranchNames.length) return;
    final branchIndex = getIndexOfBranch(isMobileBreakpoint, showProfilesAction, actionBranchNames[actionIndex]);
    if (branchIndex < 0) return;
    navigationShell.goBranch(branchIndex, initialLocation: branchIndex == navigationShell.currentIndex);
  }

  List<ShellRouteAction> _actions(Translations t, bool isMobileBreakpoint) => isMobileBreakpoint
      ? [
          ShellRouteAction(Icons.person_rounded, t.pages.profileDetails.title),
          ShellRouteAction(Icons.power_settings_new_rounded, t.pages.home.title),
          ShellRouteAction(Icons.settings_rounded, t.pages.settings.title),
        ]
      : [
          ShellRouteAction(Icons.power_settings_new_rounded, t.pages.home.title),
          ShellRouteAction(Icons.settings_rounded, t.pages.settings.title),
          ShellRouteAction(Icons.person_rounded, t.pages.profileDetails.title),
          ShellRouteAction(Icons.info_rounded, t.pages.about.title),
        ];

  List<String> _actionBranchNames(bool isMobileBreakpoint) => isMobileBreakpoint
      ? ['profileMenu', 'home', 'settings']
      : ['home', 'settings', 'profileMenu', 'about'];

  List<NavigationDestination> _navDests(List<ShellRouteAction> actions) =>
      actions.map((e) => NavigationDestination(icon: Icon(e.icon), label: e.title)).toList();
  List<NavigationRailDestination> _navRailDests(List<ShellRouteAction> actions) =>
      actions.map((e) => NavigationRailDestination(icon: Icon(e.icon), label: Text(e.title))).toList();
}
