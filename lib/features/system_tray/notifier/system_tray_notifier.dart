import 'dart:io';

import 'package:flutter/material.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/window/notifier/window_notifier.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/singbox/model/singbox_config_enum.dart';
import 'package:zeon/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

part 'system_tray_notifier.g.dart';

@Riverpod(keepAlive: true)
class SystemTrayNotifier extends _$SystemTrayNotifier with TrayListener, AppLogger {
  static const _tooltipRefreshInterval = Duration(seconds: 10);

  bool _listenerAdded = false;
  String? _lastIconPath;
  String? _lastMenuSignature;
  String? _lastTooltip;
  String? _lastTooltipStatusKey;
  DateTime? _lastTooltipUpdatedAt;
  _TraySnapshot? _pendingSnapshot;
  Future<void> _trayUpdateQueue = Future.value();
  bool _trayUpdateDraining = false;

  @override
  Future<void> build() async {
    assert(PlatformUtils.isDesktop);
    if (!_listenerAdded) {
      trayManager.addListener(this);
      _listenerAdded = true;
      ref.onDispose(() {
        trayManager.removeListener(this);
        _listenerAdded = false;
      });
    }
    await _queueTrayUpdate(await _buildTraySnapshot());
  }

  Future<_TraySnapshot> _buildTraySnapshot() async {
    final t = await ref.watch(translationsProvider.future);
    final urlTestDelay = await ref
        .watch(activeProxyNotifierProvider.future)
        .catchError((e) {
          loggy.warning("error getting active proxy", e);
          return OutboundInfo(urlTestDelay: 0);
        })
        .then((connection) => connection.urlTestDelay);
    final connection = await ref
        .watch(connectionNotifierProvider.future)
        .catchError((e) {
          loggy.warning("error getting connection status", e);
          return const ConnectionStatus.disconnected();
        })
        .then((connection) => _modifyConnectionStatus(connection, urlTestDelay));
    final serviceMode = ref.watch(ConfigOptions.serviceMode);
    final serviceModeChoices = ServiceMode.choices;

    final connectionLabel = _connectionMenuLabel(connection, t);
    final serviceModeLabels = serviceModeChoices.map((e) => '${e.name}:${e.present(t)}').join('|');
    final menuSignature = [
      PlatformUtils.isLinux,
      connectionLabel,
      connection.isSwitching,
      serviceMode.name,
      t.common.dashboard,
      t.pages.settings.inbound.serviceMode,
      serviceModeLabels,
      t.common.quit,
    ].join('||');

    return _TraySnapshot(
      iconPath: _trayIconPath(connection),
      tooltip: _trayTooltip(connection, urlTestDelay, t),
      tooltipStatusKey: connectionLabel,
      menu: _trayMenu(connection, serviceMode, serviceModeChoices, t),
      menuSignature: menuSignature,
    );
  }

  Future<void> _queueTrayUpdate(_TraySnapshot snapshot) {
    _pendingSnapshot = snapshot;
    if (_trayUpdateDraining) return _trayUpdateQueue;

    _trayUpdateDraining = true;
    return _trayUpdateQueue = _trayUpdateQueue
        .catchError((Object e, StackTrace st) {
          loggy.warning('previous tray update failed', e, st);
        })
        .then((_) => _drainTrayUpdates())
        .whenComplete(() {
          _trayUpdateDraining = false;
        });
  }

  Future<void> _drainTrayUpdates() async {
    while (_pendingSnapshot != null) {
      final snapshot = _pendingSnapshot!;
      _pendingSnapshot = null;
      await _applyTraySnapshot(snapshot);
    }
  }

  Future<void> _applyTraySnapshot(_TraySnapshot snapshot) async {
    try {
      if (_lastIconPath != snapshot.iconPath) {
        await trayManager.setIcon(snapshot.iconPath, isTemplate: PlatformUtils.isMacOS);
        _lastIconPath = snapshot.iconPath;
      }

      if (!PlatformUtils.isLinux && _shouldUpdateTooltip(snapshot)) {
        await trayManager.setToolTip(snapshot.tooltip);
        _lastTooltip = snapshot.tooltip;
        _lastTooltipStatusKey = snapshot.tooltipStatusKey;
        _lastTooltipUpdatedAt = DateTime.now();
      }

      if (_lastMenuSignature != snapshot.menuSignature) {
        await trayManager.setContextMenu(snapshot.menu);
        _lastMenuSignature = snapshot.menuSignature;
      }
    } catch (e, st) {
      loggy.warning('failed to update system tray', e, st);
    }
  }

  bool _shouldUpdateTooltip(_TraySnapshot snapshot) {
    if (_lastTooltip == null) return true;
    if (_lastTooltipStatusKey != snapshot.tooltipStatusKey) return true;
    if (_lastTooltip == snapshot.tooltip) return false;

    final lastUpdate = _lastTooltipUpdatedAt;
    return lastUpdate == null || DateTime.now().difference(lastUpdate) >= _tooltipRefreshInterval;
  }

  Menu _trayMenu(
    ConnectionStatus connection,
    ServiceMode serviceMode,
    List<ServiceMode> serviceModeChoices,
    Translations t,
  ) => Menu(
    items: [
      if (PlatformUtils.isLinux) ...[MenuItem(key: 'dashboard', label: t.common.dashboard), MenuItem.separator()],
      MenuItem(key: 'connection', label: _connectionMenuLabel(connection, t), disabled: connection.isSwitching),
      if (serviceModeChoices.length > 1)
        MenuItem.submenu(
          label: t.pages.settings.inbound.serviceMode,
          icon: Assets.images.trayIconIco,
          submenu: Menu(
            items: [
              ...serviceModeChoices.map(
                (e) => MenuItem.checkbox(checked: e == serviceMode, key: e.name, label: e.present(t)),
              ),
            ],
          ),
        ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: t.common.quit),
    ],
  );

  String _connectionMenuLabel(ConnectionStatus connection, Translations t) => switch (connection) {
    Disconnected() => t.connection.connect,
    Connecting() => t.connection.connecting,
    Connected() => t.connection.disconnect,
    Disconnecting() => t.connection.disconnecting,
  };

  String _trayIconPath(ConnectionStatus status) {
    final isDarkMode = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    const images = Assets.images;
    final isWindows = PlatformUtils.isWindows;
    switch (status) {
      case Connected():
        return isWindows ? images.trayIconConnectedIco : images.trayIconConnectedPng.path;
      case Connecting():
      case Disconnecting():
        return isWindows ? images.trayIconDisconnectedIco : images.trayIconDisconnectedPng.path;
      case Disconnected():
        return isWindows
            ? isDarkMode
                  ? images.trayIconIco
                  : images.trayIconDarkIco
            : isDarkMode
            ? images.trayIconDarkPng.path
            : images.trayIconPng.path;
    }
  }

  String _trayTooltip(ConnectionStatus connection, int urlTestDelay, Translations t) {
    final r = "${Constants.appName} - ${connection.present(t)}";
    if (connection is Connected) {
      if (Platform.isMacOS) windowManager.setBadgeLabel("${urlTestDelay}ms");
      return '$r : ${urlTestDelay}ms"';
    } else {
      if (Platform.isMacOS) windowManager.setBadgeLabel("-ms");
      return r;
    }
  }

  ConnectionStatus _modifyConnectionStatus(ConnectionStatus connection, int urlTestDelay) {
    if (connection is Connected) {
      return urlTestDelay > 0 && urlTestDelay < 65000 ? const Connected() : const Connecting();
    } else {
      return connection;
    }
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    // if (menuItem.key == 'dashboard') {
    //   await ref.read(windowNotifierProvider.notifier).open();
    // }
    if (menuItem.key == 'dashboard') {
      await ref.read(windowNotifierProvider.notifier).show();
    } else if (menuItem.key == 'connection') {
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    } else if (menuItem.key == 'quit') {
      await ref.read(windowNotifierProvider.notifier).exit();
    } else {
      ServiceMode? newMode;
      for (final mode in ServiceMode.choices) {
        if (mode.name == menuItem.key) {
          newMode = mode;
          break;
        }
      }
      if (newMode == null) return;
      loggy.debug("switching service mode: [$newMode]");
      await ref.read(ConfigOptions.serviceMode.notifier).update(newMode);
    }
  }

  @override
  Future<void> onTrayIconMouseDown() async {
    // if (Platform.isMacOS) {
    //   await trayManager.popUpContextMenu();
    // } else {
    //   await ref.read(windowNotifierProvider.notifier).hideOrShow();
    // }
    await ref.read(windowNotifierProvider.notifier).showOrHide();
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }
}

class _TraySnapshot {
  const _TraySnapshot({
    required this.iconPath,
    required this.tooltip,
    required this.tooltipStatusKey,
    required this.menu,
    required this.menuSignature,
  });

  final String iconPath;
  final String tooltip;
  final String tooltipStatusKey;
  final Menu menu;
  final String menuSignature;
}

// @Riverpod(keepAlive: true)
// class SystemTrayNotifier extends _$SystemTrayNotifier with AppLogger {
//   @override
//   Future<void> build() async {
//     if (!PlatformUtils.isDesktop) return;

//     final activeProxy = await ref.watch(activeProxyNotifierProvider.future);
//     final delay = activeProxy.urlTestDelay;
//     final newConnectionStatus = delay > 0 && delay < 65000;
//     ConnectionStatus connection;
//     try {
//       connection = await ref.watch(connectionNotifierProvider.future);
//     } catch (e) {
//       loggy.warning("error getting connection status", e);
//       connection = const ConnectionStatus.disconnected();
//     }

//     final t = await ref.watch(translationsProvider.future);

//     var tooltip = Constants.appName;
//     final serviceMode = ref.watch(ConfigOptions.serviceMode);
//     if (connection is Disconnected) {
//       setIcon(connection);
//     } else if (newConnectionStatus) {
//       setIcon(const Connected());
//       tooltip = "$tooltip - ${connection.present(t)}";
//       if (newConnectionStatus) {
//         tooltip = "$tooltip : ${delay}ms";
//       } else {
//         tooltip = "$tooltip : -";
//       }
//       // else if (delay>1000)
//       //   SystemTrayNotifier.setIcon(timeout ? Disconnecting() : Connecting());
//     } else {
//       setIcon(const Disconnecting());
//       tooltip = "$tooltip - ${connection.present(t)}";
//     }
//     if (Platform.isMacOS) {
//       windowManager.setBadgeLabel("${delay}ms");
//     }
//     if (!Platform.isLinux) await trayManager.setToolTip(tooltip);

//     // final destinations = <(String label, String location)>[
//     //   (t.home.pageTitle, const HomeRoute().location),
//     //   (t.proxies.pageTitle, const ProfilesOverviewRoute().location),
//     //   (t.logs.title, const LogsOverviewRoute().location),
//     //   // (t.settings.pageTitle, const SettingsRoute().location),
//     //   (t.about.pageTitle, const AboutRoute().location),
//     // ];

//     // loggy.debug('updating system tray');

//     final menu = Menu(
//       items: [
//         MenuItem(
//           label: t.tray.dashboard,
//           onClick: (_) async {
//             await ref.read(windowNotifierProvider.notifier).open();
//           },
//         ),
//         MenuItem.separator(),
//         MenuItem.checkbox(
//           label: switch (connection) {
//             Disconnected() => t.tray.status.connect,
//             Connecting() => t.tray.status.connecting,
//             Connected() => t.tray.status.disconnect,
//             Disconnecting() => t.tray.status.disconnecting,
//           },
//           // checked: connection.isConnected,
//           checked: false,
//           disabled: connection.isSwitching,
//           onClick: (_) async {
//            await ref.read(connectionNotifierProvider.notifier).toggleConnection();
//          },
//        ),
//         MenuItem.separator(),
//         MenuItem(
//           label: t.config.serviceMode,
//           icon: Assets.images.trayIconIco,
//           disabled: true,
//         ),

//         ...ServiceMode.values.map(
//           (e) => MenuItem.checkbox(
//             checked: e == serviceMode,
//             key: e.name,
//             label: e.present(t),
//             onClick: (menuItem) async {
//               final newMode = ServiceMode.values.byName(menuItem.key!);
//               loggy.debug("switching service mode: [$newMode]");
//               await ref.read(ConfigOptions.serviceMode.notifier).update(newMode);
//             },
//           ),
//         ),

//         // MenuItem.submenu(
//         //   label: t.tray.open,
//         //   submenu: Menu(
//         //     items: [
//         //       ...destinations.map(
//         //         (e) => MenuItem(
//         //           label: e.$1,
//         //           onClick: (_) async {
//         //             await ref.read(windowNotifierProvider.notifier).open();
//         //             ref.read(routerProvider).go(e.$2);
//         //           },
//         //         ),
//         //       ),
//         //     ],
//         //   ),
//         // ),
//         MenuItem.separator(),
//         MenuItem(
//           label: t.tray.quit,
//           onClick: (_) async {
//             return ref.read(windowNotifierProvider.notifier).quit();
//           },
//         ),
//       ],
//     );

//     await trayManager.setContextMenu(menu);
//   }

//   static void setIcon(ConnectionStatus status) {
//     if (!PlatformUtils.isDesktop) return;
//     trayManager
//         .setIcon(
//           _trayIconPath(status),
//           isTemplate: Platform.isMacOS,
//         )
//         .asStream();
//   }

//   static String _trayIconPath(ConnectionStatus status) {
//     if (Platform.isWindows) {
//       final Brightness brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
//       final isDarkMode = brightness == Brightness.dark;
//       switch (status) {
//         case Connected():
//           return Assets.images.trayIconConnectedIco;
//         case Connecting():
//           return Assets.images.trayIconDisconnectedIco;
//         case Disconnecting():
//           return Assets.images.trayIconDisconnectedIco;
//         case Disconnected():
//           if (isDarkMode) {
//             return Assets.images.trayIconIco;
//           } else {
//             return Assets.images.trayIconDarkIco;
//           }
//       }
//     }
//     // const isDarkMode = false;
//     switch (status) {
//       case Connected():
//         return Assets.images.trayIconConnectedPng.path;
//       case Connecting():
//         return Assets.images.trayIconDisconnectedPng.path;
//       case Disconnecting():
//         return Assets.images.trayIconDisconnectedPng.path;
//       case Disconnected():
//         // if (isDarkMode) {
//         //   return Assets.images.trayIconDarkPng.path;
//         // } else {
//         //   return Assets.images.trayIconPng.path;
//         // }
//         return Assets.images.trayIconPng.path;
//     }
//     // return Assets.images.trayIconPng.path;
//   }
// }
