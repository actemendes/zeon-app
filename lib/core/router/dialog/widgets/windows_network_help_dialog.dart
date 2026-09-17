import 'package:flutter/material.dart';
import 'package:zeon/core/localization/translation_context.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/utils/uri_utils.dart';

/// Help for the Windows no-profile recovery path. A missing profile is not
/// evidence of a firewall block, so the copy describes it as a possibility.
class WindowsNetworkHelpDialog extends StatefulWidget {
  const WindowsNetworkHelpDialog({super.key, this.openLink});

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
  static const _fontFamilyFallback = ['Shabnam', 'Microsoft YaHei', 'Microsoft JhengHei'];
  Uri? _unopenedLink;

  Future<void> _open(Uri uri) async {
    final opened = await (widget.openLink ?? UriUtils.tryLaunch)(uri);
    if (mounted) setState(() => _unopenedLink = opened ? null : uri);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.translations.dialogs.windowsNetworkHelp;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      fontFamilyFallback: _fontFamilyFallback,
    );
    return ZeonDialog(
      maxWidth: 560,
      fontFamilyFallback: _fontFamilyFallback,
      icon: const Icon(Icons.wifi_off_rounded),
      title: Text(t.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.description),
          const SizedBox(height: 20),
          _step(
            number: '01',
            title: t.allowTitle,
            children: [
              Text(t.allowDescription),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => _open(WindowsNetworkHelpDialog.firewallUri),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text(t.exceptionsAction),
                style: FilledButton.styleFrom(
                  foregroundColor: colors.onPrimary,
                  backgroundColor: colors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 8),
              Text(t.exceptionsHint, style: captionStyle),
            ],
          ),
          const SizedBox(height: 12),
          _step(
            number: '02',
            title: t.happTitle,
            children: [
              Text(t.happDescription),
              const SizedBox(height: 12),
              Text(t.existingDevice),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => _open(WindowsNetworkHelpDialog.happUri),
                icon: const Icon(Icons.download_rounded, size: 20),
                label: Text(t.downloadHapp),
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
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: colors.onSurface),
                    onPressed: () => _open(WindowsNetworkHelpDialog.telegramUri),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: Text(t.telegram),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: colors.onSurface),
                    onPressed: () => _open(WindowsNetworkHelpDialog.vkUri),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: Text(t.vk),
                  ),
                ],
              ),
              const SelectableText('@zvo_net_bot', textDirection: TextDirection.ltr, style: TextStyle(fontSize: 14)),
            ],
          ),
          const SizedBox(height: 16),
          Text(t.restart, style: captionStyle),
          if (_unopenedLink != null) ...[
            const SizedBox(height: 12),
            Text(t.browserFailure),
            SelectableText(
              _unopenedLink.toString(),
              textDirection: TextDirection.ltr,
              style: theme.textTheme.bodySmall,
            ),
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
