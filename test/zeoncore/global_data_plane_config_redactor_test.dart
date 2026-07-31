import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/global_data_plane_config_redactor.dart';

void main() {
  test('redacts credentials endpoints and private destinations', () {
    final source = jsonEncode({
      'route': {
        'final': 'user-server-name',
        'rule_set': [
          {'tag': 'zapret-ru-domains', 'url': 'https://private.example/list.srs'},
        ],
        'rules': [
          {
            'domain': ['private.example', 'secret.internal'],
            'ip_cidr': ['203.0.113.0/24', '2001:db8::/32'],
            'outbound': 'user-server-name',
          },
        ],
      },
      'outbounds': [
        {
          'tag': 'user-server-name',
          'type': 'vless',
          'server': 'vpn.private.example',
          'server_port': 443,
          'uuid': '12345678-1234-1234-1234-123456789012',
          'password': 'TOP_SECRET',
        },
      ],
    });

    final redacted = GlobalDataPlaneConfigRedactor().redactJson(source);

    expect(redacted, isNot(contains('private.example')));
    expect(redacted, isNot(contains('secret.internal')));
    expect(redacted, isNot(contains('TOP_SECRET')));
    expect(redacted, isNot(contains('12345678-1234')));
    expect(redacted, contains('zapret-ru-domains'));
    expect(redacted, contains('tag-001'));
    expect(redacted, contains('"type": "vless"'));
    expect(redacted, contains('"ipv4Like": 1'));
    expect(redacted, contains('"ipv6Like": 1'));
  });

  test('preserves data-plane options required by effective config diff', () {
    final redacted =
        GlobalDataPlaneConfigRedactor().redact({
              'dns': {'final': 'dns-remote', 'independent_cache': true, 'strategy': 'prefer_ipv4'},
              'route': {'final': 'select', 'auto_detect_interface': false},
              'inbounds': [
                {'tag': 'tun-in', 'type': 'tun', 'mtu': 9000, 'sniff': true},
              ],
              'outbounds': [
                {
                  'tag': 'select',
                  'type': 'selector',
                  'outbounds': ['opaque-a', 'opaque-b'],
                },
              ],
            })
            as Map<String, Object?>;

    expect((redacted['route'] as Map)['final'], 'select');
    expect((redacted['dns'] as Map)['independent_cache'], true);
    expect(((redacted['inbounds'] as List).single as Map)['mtu'], 9000);
    expect((((redacted['outbounds'] as List).single as Map)['outbounds'] as List), ['tag-001', 'tag-002']);
  });
}
