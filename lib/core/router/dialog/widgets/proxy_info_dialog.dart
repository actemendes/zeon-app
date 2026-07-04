import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/features/proxy/widget/proxy_quality_indicator.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxyInfoDialog extends HookConsumerWidget {
  const ProxyInfoDialog({super.key, required this.outboundInfo});

  final OutboundInfo outboundInfo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return AlertDialog(
      title: SelectionArea(child: Text(formatOutboundTitle(outboundInfo))),
      content: OutboundInfoWidget(outboundInfo: outboundInfo),
      actions: [TextButton(onPressed: context.pop, child: Text(t.common.close))],
    );
  }
}

class OutboundInfoWidget extends HookConsumerWidget {
  const OutboundInfoWidget({super.key, required this.outboundInfo});

  final OutboundInfo outboundInfo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildTextRow(t.dialogs.proxyInfo.testDelay, formatOutboundPing(outboundInfo)),
          _buildWidgetRow('Качество', QualityBars.fromOutbound(outboundInfo)),
        ],
      ),
    );
  }

  Widget _buildTextRow(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Flexible(child: SelectableText(value, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildWidgetRow(String title, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          value,
        ],
      ),
    );
  }
}
