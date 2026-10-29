import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:zeon/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:zeon/utils/platform_utils.dart';

class SettingDetailChips<T extends Object> extends HookConsumerWidget {
  const SettingDetailChips({
    super.key,
    required this.values,
    this.t,
    this.scrollController,
    this.useEllipsis = false,
    this.isPackageName = false,
  });

  final List<T> values;
  final Map<String, String>? t;
  final ScrollController? scrollController;
  final bool useEllipsis;
  final bool isPackageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = scrollController ?? useScrollController();
    final showStartBtn = useState(false);
    final showEndBtn = useState(true);

    useEffect(() {
      void listener() {
        if (!controller.hasClients) return;
        showStartBtn.value = controller.position.pixels > controller.position.minScrollExtent;
        showEndBtn.value = controller.position.pixels < controller.position.maxScrollExtent;
      }

      controller.addListener(listener);
      return () => controller.removeListener(listener);
    }, [controller]);

    void scrollToEnd() {
      if (!controller.hasClients) return;
      controller.animateTo(
        controller.offset + 150,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }

    void scrollToStart() {
      if (!controller.hasClients) return;
      controller.animateTo(
        controller.offset - 150,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!controller.hasClients) return;
          if (controller.position.maxScrollExtent <= 0) {
            showStartBtn.value = false;
            showEndBtn.value = false;
          } else {
            showStartBtn.value = controller.position.pixels > controller.position.minScrollExtent;
            showEndBtn.value = controller.position.pixels < controller.position.maxScrollExtent;
          }
        });
        return Container(
          padding: const EdgeInsets.only(bottom: 6),
          height: 36,
          child: PlatformUtils.isDesktop
              ? Stack(
                  children: [
                    ListView.separated(
                      controller: controller,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: values.length,
                      scrollDirection: Axis.horizontal,
                      itemBuilder: (context, index) => SettingDetailChip<T>(
                        value: values[index],
                        t: t,
                        useEllipsis: useEllipsis,
                        isPackageName: isPackageName,
                      ),
                      separatorBuilder: (context, index) => const Gap(8),
                    ),
                    Row(
                      children: [
                        if (showStartBtn.value) ScrollBtn(isStart: true, onTap: scrollToStart),
                        const Spacer(),
                        if (showEndBtn.value) ScrollBtn(isStart: false, onTap: scrollToEnd),
                      ],
                    ),
                  ],
                )
              : ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: values.length,
                  scrollDirection: Axis.horizontal,
                  itemBuilder: (context, index) => SettingDetailChip<T>(
                    value: values[index],
                    t: t,
                    useEllipsis: useEllipsis,
                    isPackageName: isPackageName,
                  ),
                  separatorBuilder: (context, index) => const Gap(8),
                ),
        );
      },
    );
  }
}

class SettingDetailChip<T extends Object> extends ConsumerWidget {
  const SettingDetailChip({
    super.key,
    required this.value,
    required this.t,
    required this.useEllipsis,
    required this.isPackageName,
  });

  final T value;
  final Map<String, String>? t;
  final bool useEllipsis;
  final bool isPackageName;

  Widget valueByType(T value, ThemeData theme) {
    final cs = theme.colorScheme;
    if (value is MapEntry) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          tText('${value.key}', theme),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Container(
              width: 1,
              height: 12,
              color: cs.onSurfaceVariant.withValues(alpha: .35),
            ),
          ),
          Text(
            '${value.value}',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.primary,
            ),
          ),
        ],
      );
    } else {
      return tText('$value', theme);
    }
  }

  Widget tText(String value, ThemeData theme) {
    var text = value;
    if (useEllipsis && value.length > 24) {
      text = '${value.substring(0, 12)}...${value.substring(value.length - 10)}';
    }
    return Text(
      t == null ? text : t![text] ?? text,
      style: TextStyle(
        fontFamily: 'Montserrat',
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final strVal = '$value';
    final isWindowsExe = PlatformUtils.isDesktop && strVal.toLowerCase().endsWith('.exe');
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: isPackageName
          ? AndroidAppInfo(packageName: strVal)
          : isWindowsExe
          ? _DesktopExecutableChipContent(executablePath: strVal)
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Center(child: valueByType(value, theme)),
            ),
    );
  }
}

class _DesktopExecutableChipContent extends StatelessWidget {
  const _DesktopExecutableChipContent({required this.executablePath});

  final String executablePath;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Uint8List? icon = WindowsInstalledAppsService.extractExecutableIcon(executablePath);
    final label = WindowsInstalledAppsService.friendlyProgramName(executablePath);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 10, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(icon, width: 18, height: 18, filterQuality: FilterQuality.high),
            )
          else
            Icon(Icons.apps_rounded, size: 16, color: cs.primary),
          const Gap(6),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class AndroidAppInfo extends HookConsumerWidget {
  const AndroidAppInfo({super.key, required this.packageName});

  final String packageName;

  String useEllipsis() {
    if (packageName.length > 20) {
      return '${packageName.substring(0, 10)}...${packageName.substring(packageName.length - 10)}';
    } else {
      return packageName;
    }
  }

  Future<AppInfo?> getAppInfo() async {
    if (PlatformUtils.isDesktop && packageName.toLowerCase().endsWith('.exe')) {
      return AppInfo(
        name: WindowsInstalledAppsService.friendlyProgramName(packageName),
        icon: WindowsInstalledAppsService.extractExecutableIcon(packageName),
        packageName: packageName,
        versionName: '',
        versionCode: 1,
        builtWith: BuiltWith.native_or_others,
        installedTimestamp: 0,
      );
    }
    return await InstalledApps.getAppInfo(packageName, BuiltWith.flutter);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = useFuture<AppInfo?>(useMemoized(() => getAppInfo(), [packageName]));
    if (app.hasData && app.data != null) {
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 10, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (app.data!.icon != null) ...[
              AspectRatio(
                aspectRatio: 1.0,
                child: CircleAvatar(backgroundColor: Colors.transparent, child: Image.memory(app.data!.icon!)),
              ),
              const Gap(6),
            ],
            Text(
              app.data!.name,
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      );
    } else if (app.hasError || (app.hasData && app.data == null)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Center(
          child: Text(
            useEllipsis(),
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    } else {
      return const Padding(
        padding: EdgeInsets.all(6),
        child: AspectRatio(aspectRatio: 1.0, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
  }
}

class ScrollBtn extends ConsumerWidget {
  const ScrollBtn({super.key, required this.isStart, required this.onTap});

  final bool isStart;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    const radius = Radius.circular(8);
    final borderRadius = isStart
        ? const BorderRadiusDirectional.only(topEnd: radius, bottomEnd: radius)
        : const BorderRadiusDirectional.only(topStart: radius, bottomStart: radius);
    return Material(
      borderRadius: borderRadius,
      color: Colors.transparent,
      child: InkWell(
        borderRadius: borderRadius.resolve(Directionality.of(context)),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 28,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: borderRadius,
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: .25),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            isStart ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
            size: 18,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
