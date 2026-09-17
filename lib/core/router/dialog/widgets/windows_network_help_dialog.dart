import 'package:flutter/material.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/utils/uri_utils.dart';

/// Help for the Windows no-profile recovery path. A missing profile is not
/// evidence of a firewall block, so the copy describes it as a possibility.
class WindowsNetworkHelpDialog extends StatefulWidget {
  const WindowsNetworkHelpDialog({super.key, required this.russian, this.openLink});

  final bool russian;
  final Future<bool> Function(Uri)? openLink;

  static final firewallUri = Uri.parse(
    'https://bisv.ru/blog/dobavlenie-isklyucheniy-v-brandmauery-windows-10-i-windows-11-vmesto-otklyucheniya/',
  );
  static final happUri = Uri.parse('https://github.com/Happ-proxy/happ-desktop/releases');
  static final telegramUri = Uri.parse('https://t.me/zvo_net_bot');
  static final vkUri = Uri.parse('https://vk.com/zvo_net');

  @override
  State<WindowsNetworkHelpDialog> createState() => _WindowsNetworkHelpDialogState();
}

class _WindowsNetworkHelpDialogState extends State<WindowsNetworkHelpDialog> {
  Uri? _unopenedLink;

  String _text(String ru, String en) => widget.russian ? ru : en;

  Future<void> _open(Uri uri) async {
    final opened = await (widget.openLink ?? UriUtils.tryLaunch)(uri);
    if (mounted) setState(() => _unopenedLink = opened ? null : uri);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ZeonDialog(
      maxWidth: 560,
      icon: const Icon(Icons.wifi_off_rounded),
      title: Text(_text('НЕ УДАЛОСЬ ПОДКЛЮЧИТЬСЯ', 'UNABLE TO CONNECT')),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _text(
              'Профиль подключения пока не загрузился. Возможно, доступ к сети блокирует '
                  'брандмауэр Windows или антивирус, например Касперский.',
              'Your connection profile has not loaded yet. Windows Firewall or an antivirus, '
                  'such as Kaspersky, may be blocking network access.',
            ),
          ),
          const SizedBox(height: 20),
          _step(
            number: '01',
            title: _text('Разрешите доступ ZEON', 'Allow ZEON to access the network'),
            children: [
              Text(
                _text(
                  'Добавьте ZEON в исключения брандмауэра или антивируса.',
                  'Add ZEON to your firewall or antivirus exceptions.',
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => _open(WindowsNetworkHelpDialog.firewallUri),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text(_text('Как добавить исключение', 'How to add an exception')),
                style: FilledButton.styleFrom(
                  foregroundColor: colors.onPrimary,
                  backgroundColor: colors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _text('Инструкция для Windows 10 и 11', 'Instructions for Windows 10 and 11'),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _step(
            number: '02',
            title: _text('Не помогло? Попробуйте Happ', 'Still not working? Try Happ'),
            children: [
              Text(
                _text(
                  'Установите Happ и получите ссылку для подключения у нашего бота '
                      'в Telegram или ВКонтакте.',
                  'Install Happ and get a connection link from our bot on Telegram or VK.',
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => _open(WindowsNetworkHelpDialog.happUri),
                icon: const Icon(Icons.download_rounded, size: 20),
                label: Text(_text('Скачать Happ для Windows', 'Download Happ for Windows')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.onSurface,
                  side: BorderSide(color: colors.onSurface.withValues(alpha: .22)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: colors.onSurface),
                    onPressed: () => _open(WindowsNetworkHelpDialog.telegramUri),
                    child: const Text('Telegram ↗'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: colors.onSurface),
                    onPressed: () => _open(WindowsNetworkHelpDialog.vkUri),
                    child: Text(_text('ВКонтакте ↗', 'VK ↗')),
                  ),
                ],
              ),
              const SelectableText('@zvo_net_bot', style: TextStyle(fontSize: 14)),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _text('После изменения настроек перезапустите ZEON.', 'Restart ZEON after changing your settings.'),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (_unopenedLink != null) ...[
            const SizedBox(height: 12),
            Text(
              _text('Не удалось открыть браузер. Скопируйте ссылку:', 'Could not open your browser. Copy this link:'),
            ),
            SelectableText(_unopenedLink.toString(), style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _step({required String number, required String title, required List<Widget> children}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(number, style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: colors.onSurface),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
