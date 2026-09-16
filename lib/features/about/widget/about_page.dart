import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/app_info/app_info_provider.dart';
import 'package:zeon/core/directories/directories_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/constants.dart';
import 'package:zeon/core/ui/ui_names.dart';
import 'package:zeon/features/settings/widget/settings_surface.dart';
import 'package:zeon/utils/utils.dart';

class AboutPage extends HookConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final appInfo = ref.watch(appInfoProvider).requireValue;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final logoAsset = theme.brightness == Brightness.dark
        ? 'assets/images/SVG/big-logo-dark.svg'
        : 'assets/images/SVG/big-logo-light.svg';

    return Scaffold(
      key: const ValueKey(UiNames.screenAbout),
      appBar: AppBar(
        centerTitle: false,
        titleTextStyle: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
        title: Text(t.pages.about.title.toUpperCase()),
      ),
      body: SettingsList(
        children: [
          Container(
            key: const ValueKey('about_identity'),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(34)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SvgPicture.asset(logoAsset, width: 156, semanticsLabel: t.common.appTitle),
                      ),
                    ),
                    const SizedBox(width: 16),
                    IconButton.filledTonal(
                      key: const ValueKey('about_copy_info'),
                      tooltip: t.common.addToClipboard,
                      onPressed: () => Clipboard.setData(ClipboardData(text: appInfo.format())),
                      style: IconButton.styleFrom(
                        backgroundColor: cs.surface,
                        foregroundColor: cs.onSurface,
                        minimumSize: const Size(48, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      icon: const Icon(Icons.copy_rounded, size: 21),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(t.common.version, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 6),
                Text(appInfo.presentVersion, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SettingsGroup(
            children: [
              SettingsTile(
                title: Text(t.pages.about.termsAndConditions),
                leading: const Icon(Icons.description_outlined),
                trailing: const Icon(Icons.arrow_outward_rounded),
                onTap: () => UriUtils.tryLaunch(Uri.parse(Constants.termsAndConditionsUrl)),
              ),
              SettingsTile(
                title: Text(t.pages.about.privacyPolicy),
                leading: const Icon(Icons.shield_outlined),
                trailing: const Icon(Icons.arrow_outward_rounded),
                onTap: () => UriUtils.tryLaunch(Uri.parse(Constants.privacyPolicyUrl)),
              ),
            ],
          ),
          if (PlatformUtils.isDesktop)
            SettingsGroup(
              children: [
                SettingsTile(
                  title: Text(t.pages.about.openWorkingDir),
                  leading: const Icon(Icons.folder_outlined),
                  trailing: const Icon(Icons.open_in_new_rounded),
                  onTap: () async {
                    final path = ref.read(appDirectoriesProvider).requireValue.workingDir.uri;
                    await UriUtils.tryLaunch(path);
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}
