// Read-only core inspection. Android: adb forward tcp:28179 tcp:18179.
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:grpc/grpc.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';

Future<String> safeId(String value) async {
  final digest = await Sha256().hash(utf8.encode(value));
  return digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().substring(0, 12);
}

String trimNativeTag(String value) => value.split('§').first.split('В§').first.trim();

OutboundInfo? resolveRuntimeLeaf(OutboundGroupList groups, String nativeReport) {
  final selected = groups.items.where((group) => group.tag == 'select').first;
  final selectedTag = trimNativeTag(selected.selected);
  final prefix = '$selectedTag -> ';
  final leafReport = nativeReport.startsWith(prefix) ? nativeReport.substring(prefix.length) : nativeReport;
  final matches = <String, OutboundInfo>{
    for (final item in groups.items.expand((group) => group.items))
      if (!item.isGroup && trimNativeTag(item.tag) == leafReport) item.tag: item,
  };
  // An empty/group-only or ambiguous report is not proof of a concrete server.
  return matches.length == 1 ? matches.values.single : null;
}

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Expected forwarded loopback port');
  final channel = ClientChannel(
    '127.0.0.1',
    port: int.parse(args.single),
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  try {
    final client = CoreClient(channel);
    final options = CallOptions(timeout: const Duration(seconds: 8));
    final status = await client.coreInfoListener(Empty(), options: options).first;
    final groups = await client.outboundsInfo(Empty(), options: options).first;
    final stats = await client.getSystemInfo(Empty(), options: options);
    final selected = groups.items.where((g) => g.tag == 'select').first;
    final selectedItems = selected.items.where((item) => item.tag == selected.selected);
    final runtimeLeaf = resolveRuntimeLeaf(groups, stats.currentOutbound);
    stdout.writeln(
      jsonEncode({
        'core_status': status.coreState.toString(),
        'selector': await safeId(selected.tag),
        'selected_id': await safeId(selected.selected),
        'selected_display': selectedItems.isEmpty ? null : selectedItems.first.tagDisplay,
        'auto_selected': selected.selected == 'balance',
        'native_report_id': await safeId(stats.currentOutbound),
        'runtime_outbound_id': runtimeLeaf == null ? null : await safeId(runtimeLeaf.tag),
        'runtime_outbound_display': runtimeLeaf?.tagDisplay,
        'runtime_outbound_present': runtimeLeaf != null,
      }),
    );
  } finally {
    await channel.shutdown();
  }
}
