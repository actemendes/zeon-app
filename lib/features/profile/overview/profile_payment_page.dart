import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum _SubscriptionPlan {
  one(months: 1, amountRub: 150, code: '1m'),
  three(months: 3, amountRub: 400, code: '3m'),
  six(months: 6, amountRub: 700, code: '6m'),
  twelve(months: 12, amountRub: 1200, code: '12m');

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
    final headingColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFF3B444D);
    final maxContentWidth = switch (breakpoint.activeBreakpoint) {
      Breakpoints.mobile => double.infinity,
      Breakpoints.tablet => 720.0,
      Breakpoints.desktop => 920.0,
    };

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(gradient: _headerGradient),
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
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
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
                      _FeatureItem(
                        text: t.pages.profileDetails.specialServers.features.noSupport,
                        icon: Icons.devices_other_rounded,
                      ),
                      const SizedBox(height: 12),
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
            onPlanSelected: (plan) => selectedPlan.value = plan,
            connectLabel: t.pages.profileDetails.specialServers.connect,
            onConnectTap: () => _openCheckout(context, t, selectedPlan.value),
          ),
        ],
      ),
    );
  }

  Future<void> _openCheckout(BuildContext context, Translations t, _SubscriptionPlan plan) async {
    final checkoutUri = Uri(
      scheme: 'youkassa',
      host: 'pay',
      queryParameters: {'plan': plan.code, 'months': '${plan.months}', 'amount': '${plan.amountRub}'},
    );
    final isOpened = await UriUtils.tryLaunch(checkoutUri);
    if (!context.mounted || isOpened) return;
    CustomToast.error(t.pages.profileDetails.specialServers.paymentLaunchError).show(context);
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
    required this.onConnectTap,
  });

  final String title;
  final _SubscriptionPlan selectedPlan;
  final ({String one, String three, String six, String twelve}) optionLabels;
  final ValueChanged<_SubscriptionPlan> onPlanSelected;
  final String connectLabel;
  final VoidCallback onConnectTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final panelColor = theme.brightness == Brightness.dark ? const Color(0xFF000000) : const Color(0xFFE4EFF4);

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Container(
          decoration: BoxDecoration(color: panelColor, borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
                onTap: () => onPlanSelected(_SubscriptionPlan.one),
              ),
              const SizedBox(height: 8),
              _PlanTile(
                label: optionLabels.three,
                price: _formatPrice(_SubscriptionPlan.three.amountRub),
                selected: selectedPlan == _SubscriptionPlan.three,
                onTap: () => onPlanSelected(_SubscriptionPlan.three),
              ),
              const SizedBox(height: 8),
              _PlanTile(
                label: optionLabels.six,
                price: _formatPrice(_SubscriptionPlan.six.amountRub),
                selected: selectedPlan == _SubscriptionPlan.six,
                onTap: () => onPlanSelected(_SubscriptionPlan.six),
              ),
              const SizedBox(height: 8),
              _PlanTile(
                label: optionLabels.twelve,
                price: _formatPrice(_SubscriptionPlan.twelve.amountRub),
                selected: selectedPlan == _SubscriptionPlan.twelve,
                onTap: () => onPlanSelected(_SubscriptionPlan.twelve),
              ),
              const SizedBox(height: 12),
              _ConnectButton(label: connectLabel, onTap: onConnectTap),
            ],
          ),
        ),
      ),
    );
  }

  String _formatPrice(int value) => '$value \u20BD';
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({required this.label, required this.price, required this.selected, required this.onTap});

  final String label;
  final String price;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultBackground = theme.brightness == Brightness.dark ? const Color(0xFF1A1B1F) : const Color(0xFFD6E1E5);
    const selectedBorderColor = Color(0xFF1AE958);
    final textColor = theme.colorScheme.onSurface;
    final priceColor = theme.brightness == Brightness.dark ? const Color(0xFFC3C6CF) : const Color(0xFF969696);

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
          onTap: onTap,
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
                      color: textColor,
                    ),
                  ),
                ),
                Text(
                  price,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                    color: priceColor,
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
  const _ConnectButton({required this.label, required this.onTap});

  static const _textHorizontalPadding = 20.0;
  static const _arrowSize = 24.0;
  static const _arrowVisualScale = 1.18;

  final String label;
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
          onTap: onTap,
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
