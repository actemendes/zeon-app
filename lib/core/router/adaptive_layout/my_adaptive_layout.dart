import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/router/adaptive_layout/shell_route_action.dart';
import 'package:zeon/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:zeon/core/router/go_router/routing_config_notifier.dart';
import 'package:zeon/core/theme/system_bars_style.dart';
import 'package:zeon/features/home/widget/home_premium_access_button.dart';
import 'package:zeon/features/stats/widget/side_bar_stats_overview.dart';

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
    final breakpoint = Breakpoint(context);
    final extendedNavigation = breakpoint.isDesktop() && !breakpoint.isCompactHeight();
    final actions = _actions(t, isMobileBreakpoint);
    final actionBranchNames = _actionBranchNames(isMobileBreakpoint);
    final currentBranchName = getNameOfBranch(isMobileBreakpoint, showProfilesAction, navigationShell.currentIndex);
    final selectedBranchName = currentBranchName == 'profiles' ? 'profileMenu' : currentBranchName;
    final selectedActionIndex = actionBranchNames.indexOf(selectedBranchName);
    final navSelectedIndex = selectedActionIndex >= 0 ? selectedActionIndex : 0;
    // focus switch management
    final previousFocus = useRef<FocusNode?>(null);
    final pressedArrow = useRef<LogicalKeyboardKey?>(null);
    final navScopeNode = useFocusScopeNode();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    useEffect(() {
      void focusPane(FocusScopeNode scope) {
        final scopeContext = scope.context;
        if (scopeContext == null) return;
        final target = scope.focusedChild ?? FocusTraversalGroup.of(scopeContext).findFirstFocus(scope);
        target?.requestFocus();
      }

      bool handler(KeyEvent event) {
        final arrows = isMobileBreakpoint ? KeyboardConst.verticalArrows : KeyboardConst.horizontalArrows;
        if (!arrows.contains(event.logicalKey)) return false;
        if (event is KeyDownEvent) {
          previousFocus.value = FocusManager.instance.primaryFocus;
          pressedArrow.value = event.logicalKey;
          return false;
        }
        if (event is! KeyUpEvent || pressedArrow.value != event.logicalKey) return false;
        pressedArrow.value = null;
        final primaryFocus = FocusManager.instance.primaryFocus;
        if (primaryFocus != previousFocus.value) return false;
        // A dialog owns its traversal; the shell must never pull focus out of it.
        final focusContext = primaryFocus?.context;
        if (focusContext != null && ModalRoute.of(focusContext) is PopupRoute) return false;
        // Cursor movement consumes arrows without changing the focused node.
        if (focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) return false;
        final towardsNavigation = isMobileBreakpoint
            ? LogicalKeyboardKey.arrowDown
            : rtl
            ? LogicalKeyboardKey.arrowRight
            : LogicalKeyboardKey.arrowLeft;
        final towardsContent = isMobileBreakpoint
            ? LogicalKeyboardKey.arrowUp
            : rtl
            ? LogicalKeyboardKey.arrowLeft
            : LogicalKeyboardKey.arrowRight;
        // Only cross the shared edge. The outer screen edges stay in their pane.
        if (event.logicalKey == towardsNavigation && branchesScope.values.any((node) => node.hasFocus)) {
          focusPane(navScopeNode);
          return true;
        }
        if (event.logicalKey == towardsContent && navScopeNode.hasFocus) {
          final branch =
              branchesScope[getNameOfBranch(isMobileBreakpoint, showProfilesAction, navigationShell.currentIndex)];
          if (branch != null) focusPane(branch);
          return true;
        }
        return false;
      }

      HardwareKeyboard.instance.addHandler(handler);
      return () {
        HardwareKeyboard.instance.removeHandler(handler);
      };
    }, [isMobileBreakpoint, showProfilesAction, navigationShell.currentIndex, rtl]);
    return Material(
      child: Scaffold(
        // Paint branch backgrounds behind the rounded mobile panel. Scaffold
        // supplies its height as bottom padding for safe content placement.
        extendBody: isMobileBreakpoint,
        // Keep the Scaffold surface edge-to-edge while protecting branch
        // controls from the bottom/side insets. Branch AppBars own the top
        // inset, so it must not be consumed twice here.
        body: SafeArea(
          top: false,
          // Home owns its SafeArea; SettingsList reserves the bottom inset
          // inside its scrollable so content can paint behind the corners.
          bottom: !isMobileBreakpoint || (currentBranchName != 'home' && currentBranchName != 'settings'),
          child: isMobileBreakpoint
              ? navigationShell
              : Row(
                  children: [
                    FocusScope(
                      node: navScopeNode,
                      child: NavigationRail(
                        extended: extendedNavigation,
                        scrollable: breakpoint.isCompactHeight(),
                        destinations: _navRailDests(actions),
                        selectedIndex: navSelectedIndex,
                        onDestinationSelected: (index) => _onTap(index, actionBranchNames),
                        trailing: extendedNavigation
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
        ),
        bottomNavigationBar: isMobileBreakpoint
            ? FocusScope(
                node: navScopeNode,
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: navigationBarStyleFor(Theme.of(context).brightness),
                  child: Material(
                    color:
                        Theme.of(context).navigationBarTheme.backgroundColor ?? Theme.of(context).colorScheme.surface,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(34)),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SafeArea(
                          top: false,
                          bottom: false,
                          child: Padding(
                            padding: EdgeInsets.only(top: 18),
                            child: HomePremiumAccessButton(padding: EdgeInsets.fromLTRB(16, 0, 16, 4)),
                          ),
                        ),
                        NavigationBar(
                          animationDuration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : null,
                          backgroundColor: Colors.transparent,
                          elevation: 0,
                          maintainBottomViewPadding: true,
                          selectedIndex: navSelectedIndex,
                          destinations: _navDests(actions),
                          onDestinationSelected: (index) => _onTap(index, actionBranchNames),
                        ),
                      ],
                    ),
                  ),
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

  List<String> _actionBranchNames(bool isMobileBreakpoint) =>
      isMobileBreakpoint ? ['profileMenu', 'home', 'settings'] : ['home', 'settings', 'profileMenu', 'about'];

  List<NavigationDestination> _navDests(List<ShellRouteAction> actions) =>
      actions.map((e) => NavigationDestination(icon: Icon(e.icon), label: e.title)).toList();
  List<NavigationRailDestination> _navRailDests(List<ShellRouteAction> actions) =>
      actions.map((e) => NavigationRailDestination(icon: Icon(e.icon), label: Text(e.title))).toList();
}
