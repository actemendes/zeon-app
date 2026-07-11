import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/diagnostics/network_diagnostic_variant.dart';

class NetworkDiagnosticsPage extends HookConsumerWidget {
  const NetworkDiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(sharedPreferencesProvider);
    final variant = useState<NetworkDiagnosticVariant?>(null);

    useEffect(() {
      preferences.whenData((prefs) {
        variant.value ??= NetworkDiagnosticVariantStore.read(prefs);
      });
      return null;
    }, [preferences]);

    Future<void> save(SharedPreferences prefs, NetworkDiagnosticVariant next) async {
      await NetworkDiagnosticVariantStore.write(prefs, next);
      variant.value = next;
      NetworkDiagnosticVariantStore.logVariant(next, udpProbeEffective: !next.disableUdpProbe);
    }

    return Scaffold(
      appBar: AppBar(title: const Text("NETWORK DIAGNOSTICS")),
      body: switch (preferences) {
        AsyncData(value: final prefs) when variant.value != null => _NetworkDiagnosticsBody(
          preferences: prefs,
          variant: variant.value!,
          onChanged: (next) => save(prefs, next),
        ),
        AsyncError(:final error) => Center(child: Text(error.toString())),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _NetworkDiagnosticsBody extends StatelessWidget {
  const _NetworkDiagnosticsBody({required this.preferences, required this.variant, required this.onChanged});

  final SharedPreferences preferences;
  final NetworkDiagnosticVariant variant;
  final ValueChanged<NetworkDiagnosticVariant> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!NetworkDiagnosticVariantStore.isAvailable) {
      return const Center(child: Text("Android debug build only"));
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _VariantSummary(variant: variant),
        const Divider(),
        SwitchListTile(
          title: const Text("Traffic hooks"),
          subtitle: const Text("Variant B disables these hooks"),
          value: variant.trafficHooksEnabled,
          onChanged: (value) => onChanged(variant.copyWith(disableTrafficHooks: !value)),
        ),
        SwitchListTile(
          title: const Text("UDP probe allowed"),
          subtitle: const Text("Variant C disables UDP probe"),
          value: !variant.disableUdpProbe,
          onChanged: (value) => onChanged(variant.copyWith(disableUdpProbe: !value)),
        ),
        SwitchListTile(
          title: const Text("Force IPv4"),
          value: variant.forceIpv4,
          onChanged: (value) => onChanged(variant.copyWith(forceIpv4: value)),
        ),
        SwitchListTile(
          title: const Text("Disable QUIC"),
          value: variant.disableQuic,
          onChanged: (value) => onChanged(variant.copyWith(disableQuic: value)),
        ),
        SwitchListTile(
          title: const Text("Route trace"),
          value: variant.enableRouteTrace,
          onChanged: (value) => onChanged(variant.copyWith(enableRouteTrace: value)),
        ),
        ListTile(
          title: const Text("MTU override"),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mtu in const [0, 1500, 1400, 1380, 1280])
                  ChoiceChip(
                    label: Text(mtu == 0 ? "current" : "$mtu"),
                    selected: variant.overrideMtu == mtu,
                    onSelected: (_) => onChanged(variant.copyWith(overrideMtu: mtu)),
                  ),
              ],
            ),
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _VariantButton(label: "A current", variant: NetworkDiagnosticVariantStore.current, onChanged: onChanged),
              _VariantButton(
                label: "B no hooks",
                variant: NetworkDiagnosticVariantStore.withoutTrafficHooks,
                onChanged: onChanged,
              ),
              _VariantButton(
                label: "C no UDP probe",
                variant: NetworkDiagnosticVariantStore.withoutUdpProbe,
                onChanged: onChanged,
              ),
              _VariantButton(
                label: "D no QUIC",
                variant: NetworkDiagnosticVariantStore.quicDisabled,
                onChanged: onChanged,
              ),
              _VariantButton(label: "E IPv4", variant: NetworkDiagnosticVariantStore.ipv4Only, onChanged: onChanged),
              _VariantButton(label: "F MTU 1400", variant: NetworkDiagnosticVariantStore.mtu1400, onChanged: onChanged),
              _VariantButton(label: "G MTU 1380", variant: NetworkDiagnosticVariantStore.mtu1380, onChanged: onChanged),
              _VariantButton(label: "H MTU 1280", variant: NetworkDiagnosticVariantStore.mtu1280, onChanged: onChanged),
              OutlinedButton.icon(
                onPressed: () async {
                  await NetworkDiagnosticVariantStore.reset(preferences);
                  onChanged(const NetworkDiagnosticVariant());
                },
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text("Reset"),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VariantSummary extends StatelessWidget {
  const _VariantSummary({required this.variant});

  final NetworkDiagnosticVariant variant;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bug_report_rounded),
      title: const Text("Active diagnostic variant"),
      subtitle: Text(variant.describe(udpProbeEffective: !variant.disableUdpProbe)),
    );
  }
}

class _VariantButton extends StatelessWidget {
  const _VariantButton({required this.label, required this.variant, required this.onChanged});

  final String label;
  final NetworkDiagnosticVariant variant;
  final ValueChanged<NetworkDiagnosticVariant> onChanged;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(onPressed: () => onChanged(variant), child: Text(label));
  }
}
