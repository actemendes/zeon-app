import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

void main() {
  test('combined health sort keeps checking below ready and above bad', () {
    final ready = OutboundInfo(
      tag: 'ready-good',
      tagDisplay: 'Ready Good',
      urlTestDelay: 120,
      combinedHealthScore: 82,
      combinedHealthLevel: 'good',
    );
    final checking = OutboundInfo(
      tag: 'checking',
      tagDisplay: 'Checking',
      urlTestDelay: 45,
      qualityScore: 95,
      qualityLevel: 'excellent',
      combinedHealthLevel: 'unknown',
      healthReason: 'speed-checking',
    );
    final bad = OutboundInfo(
      tag: 'bad',
      tagDisplay: 'Bad',
      urlTestDelay: 65535,
      qualityLevel: 'bad',
      combinedHealthLevel: 'bad',
    );

    final sorted = sortProxyItemsByCombinedHealth([checking, bad, ready]);

    expect(sorted.map((proxy) => proxy.tag), ['ready-good', 'checking', 'bad']);
  });
}
