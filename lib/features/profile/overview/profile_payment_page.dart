import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/core/ui/ui_names.dart';
import 'package:hiddify/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:hiddify/features/mobile/data/mobile_payment_service.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum _SubscriptionPlan {
  one(months: 1, amountRub: 150, code: '1'),
  three(months: 3, amountRub: 400, code: '3'),
  six(months: 6, amountRub: 700, code: '6'),
  twelve(months: 12, amountRub: 1200, code: '12');

  const _SubscriptionPlan({required this.months, required this.amountRub, required this.code});

  final int months;
  final int amountRub;
  final String code;
}

class ProfilePaymentPage extends HookConsumerWidget {
  const ProfilePaymentPage({super.key});

  static const _headerGradient = LinearGradient(colors: [Color(0xFF3CE74F), Color(0xFFBFDD71)]);
  static const _operatorAssetPaths = <String>[
    'assets/images/2x/operator-mts@2x.png',
    'assets/images/2x/operator-megaphone@2x.png',
    'assets/images/2x/operator-beeline@2x.png',
    'assets/images/2x/operator-t2@2x.png',
    'assets/images/2x/operator-yota@2x.png',
    'assets/images/2x/operator-tmob@2x.png',
  ];

  static const _ctaBackgroundAsset = 'assets/images/1x/cta-background.png';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final breakpoint = Breakpoint(context);
    final selectedPlan = useState(_SubscriptionPlan.one);
    final isProcessingPayment = useState(false);
    final paymentResultState = useState<_PaymentResultState?>(null);
    final lastHandledSid = useRef<String?>(null);
    final paymentService = useMemoized(
      () => MobilePaymentService(
        httpClient: ref.read(httpClientProvider),
        preferences: ref.read(sharedPreferencesProvider).requireValue,
        connLinkImportService: ref.read(mobileConnLinkImportServiceProvider),
      ),
      const [],
    );
    final sidFromRoute = GoRouterState.of(context).uri.queryParameters["sid"]?.trim();

    useEffect(() {
      if (sidFromRoute == null || sidFromRoute.isEmpty) return null;
      if (lastHandledSid.value == sidFromRoute) return null;
      lastHandledSid.value = sidFromRoute;
      Future<void>(() async {
        await _processPaymentReturn(
          sidFromRoute,
          paymentService: paymentService,
          isProcessingPayment: isProcessingPayment,
          paymentResultState: paymentResultState,
        );
      });
      return null;
    }, [sidFromRoute, paymentService]);

    final headingColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);
    final maxContentWidth = switch (breakpoint.activeBreakpoint) {
      Breakpoints.mobile => double.infinity,
      Breakpoints.tablet => 720.0,
      Breakpoints.desktop => 920.0,
    };

    return Scaffold(
      key: const ValueKey(UiNames.screenProfilePayment),
      backgroundColor: theme.colorScheme.surface,
      body: Stack(
        children: [
          Column(
            children: [
              Container(
                width: double.infinity,
                decoration: const BoxDecoration(gradient: _headerGradient),
                child: SafeArea(
                  bottom: false,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxContentWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 12, 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _PaymentHeaderTitle(
                                lineOne: t.pages.profileDetails.specialServers.headerLineOne,
                                lineTwo: t.pages.profileDetails.specialServers.headerLineTwo,
                                color: headingColor,
                              ),
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                              icon: Icon(Icons.close_rounded, color: headingColor),
                              onPressed: isProcessingPayment.value ? null : () => Navigator.of(context).maybePop(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxContentWidth),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FeatureItem(
                            text: t.pages.profileDetails.specialServers.features.prioritySupport,
                            icon: Icons.support_agent_rounded,
                          ),
                          const SizedBox(height: 12),
                          // _FeatureItem(
                          //   text: t.pages.profileDetails.specialServers.features.noSupport,
                          //   icon: Icons.devices_other_rounded,
                          // ),
                          // const SizedBox(height: 12),
                          _FeatureItem(
                            text: t.pages.profileDetails.specialServers.features.parkingCoverage,
                            icon: Icons.signal_cellular_alt_rounded,
                          ),
                          const SizedBox(height: 20),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: _ServersCard(
                                  label: t.pages.profileDetails.specialServers.serversLabel,
                                  value: t.pages.profileDetails.specialServers.serversValue,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _OperatorsCard(
                                  label: t.pages.profileDetails.specialServers.operatorsLabel,
                                  operatorAssetPaths: _operatorAssetPaths,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _BottomSubscriptionPanel(
                title: t.pages.profileDetails.specialServers.subscriptionTitle,
                selectedPlan: selectedPlan.value,
                optionLabels: (
                  one: t.pages.profileDetails.specialServers.plans.oneMonth,
                  three: t.pages.profileDetails.specialServers.plans.threeMonths,
                  six: t.pages.profileDetails.specialServers.plans.sixMonths,
                  twelve: t.pages.profileDetails.specialServers.plans.twelveMonths,
                ),
                onPlanSelected: isProcessingPayment.value ? null : (plan) => selectedPlan.value = plan,
                connectLabel: t.pages.profileDetails.specialServers.connect,
                isLoading: isProcessingPayment.value,
                onConnectTap: () => _openCheckout(
                  context,
                  t,
                  selectedPlan.value,
                  paymentService: paymentService,
                  isProcessingPayment: isProcessingPayment,
                ),
              ),
            ],
          ),
          if (isProcessingPayment.value)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: .18)),
                  child: const Center(
                    child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.4)),
                  ),
                ),
              ),
            ),
          if (paymentResultState.value != null)
            Positioned.fill(
              child: _PaymentResultOverlay(
                state: paymentResultState.value!,
                onClose: paymentResultState.value == _PaymentResultState.waiting && isProcessingPayment.value
                    ? null
                    : () => paymentResultState.value = null,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _processPaymentReturn(
    String sid, {
    required MobilePaymentService paymentService,
    required ValueNotifier<bool> isProcessingPayment,
    required ValueNotifier<_PaymentResultState?> paymentResultState,
  }) async {
    if (sid.trim().isEmpty) return;
    if (isProcessingPayment.value) return;

    isProcessingPayment.value = true;
    paymentResultState.value = _PaymentResultState.waiting;

    try {
      final result = await paymentService.processPaymentSessionReturn(sid: sid);
      switch (result.state) {
        case PaymentSessionState.pending:
          paymentResultState.value = _PaymentResultState.waiting;
        case PaymentSessionState.succeeded:
          paymentResultState.value = _PaymentResultState.succeeded;
        case PaymentSessionState.canceled:
          paymentResultState.value = _PaymentResultState.canceled;
        case PaymentSessionState.failed:
          paymentResultState.value = _PaymentResultState.failed;
      }
    } catch (_) {
      paymentResultState.value = _PaymentResultState.failed;
    } finally {
      isProcessingPayment.value = false;
    }
  }

  Future<void> _openCheckout(
    BuildContext context,
    Translations t,
    _SubscriptionPlan plan, {
    required MobilePaymentService paymentService,
    required ValueNotifier<bool> isProcessingPayment,
  }) async {
    if (isProcessingPayment.value) return;
    isProcessingPayment.value = true;
    try {
      const retryDelaysSeconds = <int>[3, 5, 10, 15, 20, 25, 30, 35, 40];
      const maxAttempts = 10;

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final checkout = await paymentService.createPayment(plan: plan.code);
        if (checkout != null) {
          final paymentUri = Uri.tryParse(checkout.confirmationUrl);
          if (paymentUri != null) {
            final opened = await UriUtils.tryLaunch(paymentUri);
            if (!context.mounted || opened) return;
          }
        }

        if (attempt < maxAttempts) {
          await Future.delayed(Duration(seconds: retryDelaysSeconds[attempt - 1]));
        }
      }

      if (context.mounted) {
        CustomToast.error(t.pages.profileDetails.specialServers.paymentLaunchError).show(context);
      }
    } finally {
      isProcessingPayment.value = false;
    }
  }
}

enum _PaymentResultState { waiting, succeeded, canceled, failed }

class _PaymentResultOverlay extends StatelessWidget {
  const _PaymentResultOverlay({required this.state, required this.onClose});

  final _PaymentResultState state;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (state) {
      _PaymentResultState.waiting => "Waiting for confirmation",
      _PaymentResultState.succeeded => "Payment successful",
      _PaymentResultState.canceled => "Payment canceled",
      _PaymentResultState.failed => "Payment failed",
    };
    final subtitle = switch (state) {
      _PaymentResultState.waiting => "We are checking the payment status.",
      _PaymentResultState.succeeded => "Your subscription data is being refreshed.",
      _PaymentResultState.canceled => "The payment was canceled. You can try again.",
      _PaymentResultState.failed => "Unable to confirm payment right now. Please try again.",
    };
    final icon = switch (state) {
      _PaymentResultState.waiting => null,
      _PaymentResultState.succeeded => Icons.check_circle_rounded,
      _PaymentResultState.canceled => Icons.remove_circle_outline_rounded,
      _PaymentResultState.failed => Icons.error_outline_rounded,
    };
    final iconColor = switch (state) {
      _PaymentResultState.waiting => theme.colorScheme.primary,
      _PaymentResultState.succeeded => const Color(0xFF1DAE4D),
      _PaymentResultState.canceled => const Color(0xFFAC7C19),
      _PaymentResultState.failed => theme.colorScheme.error,
    };

    return ColoredBox(
      color: Colors.black.withValues(alpha: .35),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon == null)
                    const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4))
                  else
                    Icon(icon, size: 28, color: iconColor),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: .8),
                    ),
                  ),
                  if (onClose != null) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: onClose,
                        child: Text(MaterialLocalizations.of(context).okButtonLabel),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaymentHeaderTitle extends StatelessWidget {
  const _PaymentHeaderTitle({required this.lineOne, required this.lineTwo, required this.color});

  final String lineOne;
  final String lineTwo;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          lineOne,
          style: theme.textTheme.titleLarge?.copyWith(
            fontFamily: 'Unbounded',
            fontWeight: FontWeight.w300,
            fontSize: 32,
            height: 27 / 32,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          lineTwo,
          style: theme.textTheme.titleLarge?.copyWith(
            fontFamily: 'Unbounded',
            fontWeight: FontWeight.w700,
            fontSize: 32,
            height: 37 / 32,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _FeatureItem extends StatelessWidget {
  const _FeatureItem({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        SizedBox.square(
          dimension: 24,
          child: Icon(icon, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: .95)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

class _ServersCard extends StatelessWidget {
  const _ServersCard({required this.label, required this.value});
  static const height = 140.0;

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      height: height,
      decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w500,
              fontSize: 14,
              color: theme.colorScheme.onSurface.withValues(alpha: .9),
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontFamily: 'Unbounded',
              fontWeight: FontWeight.w600,
              fontSize: 32,
            ),
          ),
        ],
      ),
    );
  }
}

class _OperatorsCard extends StatelessWidget {
  const _OperatorsCard({required this.label, required this.operatorAssetPaths});

  final String label;
  final List<String> operatorAssetPaths;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      height: _ServersCard.height,
      decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w500,
              fontSize: 14,
              color: theme.colorScheme.onSurface.withValues(alpha: .9),
            ),
          ),
          const Spacer(),
          Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(
              width: (32 * 3) + (10 * 2),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: operatorAssetPaths.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 32,
                ),
                itemBuilder: (context, index) {
                  return SizedBox.square(
                    dimension: 32,
                    child: Image.asset(operatorAssetPaths[index], fit: BoxFit.contain),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomSubscriptionPanel extends StatelessWidget {
  const _BottomSubscriptionPanel({
    required this.title,
    required this.selectedPlan,
    required this.optionLabels,
    required this.onPlanSelected,
    required this.connectLabel,
    required this.isLoading,
    required this.onConnectTap,
  });

  final String title;
  final _SubscriptionPlan selectedPlan;
  final ({String one, String three, String six, String twelve}) optionLabels;
  final ValueChanged<_SubscriptionPlan>? onPlanSelected;
  final String connectLabel;
  final bool isLoading;
  final VoidCallback onConnectTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final panelColor = theme.colorScheme.surface;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Container(
          // margin: const EdgeInsets.fromLTRB(0, 0, 0, 16),
          decoration: BoxDecoration(color: panelColor, borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _PlanTile(
                label: optionLabels.one,
                price: _formatPrice(_SubscriptionPlan.one.amountRub),
                selected: selectedPlan == _SubscriptionPlan.one,
                enabled: onPlanSelected != null,
                onTap: () => onPlanSelected?.call(_SubscriptionPlan.one),
              ),
              const SizedBox(height: 8),
              _PlanTile(
                label: optionLabels.three,
                price: _formatPrice(_SubscriptionPlan.three.amountRub),
                selected: selectedPlan == _SubscriptionPlan.three,
                enabled: onPlanSelected != null,
                onTap: () => onPlanSelected?.call(_SubscriptionPlan.three),
              ),
              const SizedBox(height: 8),
              _PlanTile(
                label: optionLabels.six,
                price: _formatPrice(_SubscriptionPlan.six.amountRub),
                selected: selectedPlan == _SubscriptionPlan.six,
                enabled: onPlanSelected != null,
                onTap: () => onPlanSelected?.call(_SubscriptionPlan.six),
              ),
              const SizedBox(height: 8),
              _PlanTile(
                label: optionLabels.twelve,
                price: _formatPrice(_SubscriptionPlan.twelve.amountRub),
                selected: selectedPlan == _SubscriptionPlan.twelve,
                enabled: onPlanSelected != null,
                onTap: () => onPlanSelected?.call(_SubscriptionPlan.twelve),
              ),
              const SizedBox(height: 12),
              _ConnectButton(label: connectLabel, isLoading: isLoading, onTap: onConnectTap),
            ],
          ),
        ),
      ),
    );
  }

  String _formatPrice(int value) => '$value \u20BD';
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.label,
    required this.price,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String price;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultBackground = theme.colorScheme.secondaryContainer;
    const selectedBorderColor = Color(0xFF1AE958);
    final textColor = theme.colorScheme.onSurface;
    final priceColor = theme.brightness == Brightness.dark ? const Color(0xFFC3C6CF) : const Color(0xFF969696);
    final disabledOpacity = enabled ? 1.0 : 0.55;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        height: 45,
        decoration: BoxDecoration(
          color: defaultBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? selectedBorderColor : Colors.transparent, width: selected ? 2.5 : 0),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'Montserrat',
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      color: textColor.withValues(alpha: disabledOpacity),
                    ),
                  ),
                ),
                Text(
                  price,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                    color: priceColor.withValues(alpha: disabledOpacity),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.label, required this.isLoading, required this.onTap});

  static const _textHorizontalPadding = 20.0;
  static const _arrowSize = 24.0;
  static const _arrowVisualScale = 1.18;

  final String label;
  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        height: 64,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          image: const DecorationImage(image: AssetImage(ProfilePaymentPage._ctaBackgroundAsset), fit: BoxFit.cover),
        ),
        child: InkWell(
          onTap: isLoading ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _textHorizontalPadding),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
                if (isLoading)
                  const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  SizedBox.square(
                    dimension: _arrowSize,
                    child: Center(
                      child: Transform.scale(
                        scale: _arrowVisualScale,
                        child: Icon(Icons.arrow_outward, size: _arrowSize, color: foreground),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
