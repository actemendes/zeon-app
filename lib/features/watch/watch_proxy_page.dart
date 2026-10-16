import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/proxy/overview/proxies_overview_notifier.dart';

/// Deliberately small first watch surface. Status describes the local proxy, not a VPN.
class WatchProxyPage extends ConsumerStatefulWidget {
  const WatchProxyPage({super.key});
  @override
  ConsumerState<WatchProxyPage> createState() => _WatchProxyPageState();
}

class _WatchProxyPageState extends ConsumerState<WatchProxyPage> {
  bool? permission;
  bool busy = false;
  String? error;
  static const channel = MethodChannel('com.zeon.app/platform');

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final granted = await channel.invokeMethod<bool>('watch_proxy_permission');
    if (mounted) setState(() => permission = granted == true);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => error = 'Не удалось выполнить. Повторите.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeConnectionStateProvider);
    final profile = ref.watch(activeProfileProvider).valueOrNull;
    final group = ref.watch(proxiesOverviewNotifierProvider).valueOrNull;
    final autoAvailable = group?.items.any((item) => item.tag == 'balance') ?? false;
    final autoSelected = group?.selected == 'balance';
    final stopping = state.action == MainVpnButtonAction.stop;
    final status = state.isConnected
        ? 'Прокси включён'
        : state.isStarting
        ? 'Подключение…'
        : state.isStopping
        ? 'Отключение…'
        : 'Прокси выключен';
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 30),
        children: [
          const Text(
            'ZEON',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            status,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('watch_power'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: const Color(0xff3ce74f),
              foregroundColor: Colors.black,
            ),
            onPressed: state.enabled && (stopping || (!busy && profile != null && permission == true))
                ? () => _run(() => ref.read(connectionNotifierProvider.notifier).handleMainVpnButtonTap(state))
                : null,
            child: Text(stopping ? 'Выключить' : 'Включить'),
          ),
          const SizedBox(height: 6),
          OutlinedButton(
            key: const ValueKey('watch_auto'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: Colors.white),
            onPressed: !busy && autoAvailable && !state.isStarting && !state.isStopping
                ? () =>
                      _run(() => ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group!.tag, 'balance'))
                : null,
            child: Text(autoSelected ? 'Авто ✓' : 'Авто'),
          ),
          if (permission == false)
            TextButton(onPressed: _checkPermission, child: const Text('Нужно разрешение ADB. Проверить')),
          if (profile == null)
            const Text(
              'Подготовка профиля…',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          if (error != null)
            Text(
              error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.orange),
            ),
          if (state.failureCode.isNotEmpty)
            const Text(
              'Ошибка подключения',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.orange),
            ),
          const SizedBox(height: 10),
          const Text(
            'Только приложения с поддержкой прокси.\nHTTP / SOCKS5\n127.0.0.1:12334',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
