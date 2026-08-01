import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/router/bottom_sheets/widgets/auto_apps_selection_modal.dart';
import 'package:zeon/core/router/bottom_sheets/widgets/quick_settings_modal.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/profile/overview/profiles_modal.dart';

part 'bottom_sheets_notifier.g.dart';

@riverpod
class BottomSheetsNotifier extends _$BottomSheetsNotifier {
  @override
  void build() {}

  Future<T?> _show<T>({required Widget child, required bool isScrollControlled}) async {
    final context = rootNavKey.currentContext;
    if (context == null) return null;
    // ref.read(popupCountNotifierProvider.notifier).increase();
    return await Navigator.of(context)
        .push<T>(
          ModalBottomSheetRoute(
            constraints: BottomSheetConst.boxConstraints,
            isScrollControlled: isScrollControlled,
            useSafeArea: true,
            builder: (context) => ClipRRect(
              borderRadius: BottomSheetConst.borderRadius,
              child: Material(
                child: Padding(
                  padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
                  child: child,
                ),
              ),
            ),
          ),
        )
        .then((value) {
          // ref.read(popupCountNotifierProvider.notifier).decrease();
          return value;
        });
  }

  Future<void> showProfilesOverview() async => await _show(isScrollControlled: true, child: const ProfilesModal());

  Future<void> showQuickSettings() async => await _show(isScrollControlled: false, child: const QuickSettingsModal());
  Future<void> showAutoAppsSelection({required AppProxyMode mode}) async =>
      await _show(isScrollControlled: false, child: AutoAppsSelectionModal(mode: mode));
}
