// Read-only core inspection. Android: adb forward tcp:28179 tcp:18179.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:grpc/grpc.dart';
import 'package:zeon/zeoncore/generated/v2/hcommon/common.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';

String safeId(String value) => sha256.convert(utf8.encode(value)).toString().substring(0, 12);

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
    final realItems = groups.items.expand((g) => g.items).where((item) => item.tag == stats.currentOutbound);
    stdout.writeln(
      jsonEncode({
        'core_status': status.coreState.toString(),
        'selector': safeId(selected.tag),
        'selected_id': safeId(selected.selected),
        'selected_display': selectedItems.isEmpty ? null : selectedItems.first.tagDisplay,
        'auto_selected': selected.selected == 'balance',
        'runtime_outbound_id': safeId(stats.currentOutbound),
        'runtime_outbound_display': realItems.isEmpty ? null : realItems.first.tagDisplay,
        'runtime_outbound_present': stats.currentOutbound.isNotEmpty,
      }),
    );
  } finally {
    await channel.shutdown();
  }
}
