import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
import 'package:zeon/singbox/model/singbox_rule.dart';

void main() {
  group('MobileApiProxyRoute', () {
    test('builds a forced proxy rule for an IPv4 API host', () {
      final rule = MobileApiProxyRoute.ruleFor('https://130.49.151.173/api/v1');

      expect(rule, isNotNull);
      expect(rule!.ip, '130.49.151.173/32');
      expect(rule.domains, isEmpty);
      expect(rule.outbound, RuleOutbound.proxy);
      expect(rule.toCoreJson()['outbound'], 0);
      expect(rule.toCoreJson()['ip_cidrs'], const <String>['130.49.151.173/32']);
    });

    test('builds a forced proxy rule for a domain API host', () {
      final rule = MobileApiProxyRoute.ruleFor('https://API.Example.COM/v1');

      expect(rule, isNotNull);
      expect(rule!.ip, isNull);
      expect(rule.domains, const <String>['api.example.com']);
      expect(rule.outbound, RuleOutbound.proxy);
      expect(rule.toCoreJson()['domain_suffixes'], const <String>['api.example.com']);
    });

    test('puts the API proxy rule before conflicting user routes', () {
      const directApiRule = SingboxRule(ip: '130.49.151.173/32', outbound: RuleOutbound.bypass);
      const unrelatedRule = SingboxRule(domains: <String>['example.org'], outbound: RuleOutbound.bypass);

      final rules = MobileApiProxyRoute.enforceRules(const <SingboxRule>[
        directApiRule,
        unrelatedRule,
      ], baseUrl: 'https://130.49.151.173');

      expect(rules, hasLength(3));
      expect(rules.first.ip, '130.49.151.173/32');
      expect(rules.first.outbound, RuleOutbound.proxy);
      expect(rules[1], directApiRule);
      expect(rules[2], unrelatedRule);
    });

    test('does not duplicate an existing identical mandatory rule', () {
      const mandatory = SingboxRule(ip: '130.49.151.173/32', outbound: RuleOutbound.proxy);

      final rules = MobileApiProxyRoute.enforceRules(const <SingboxRule>[mandatory], baseUrl: 'https://130.49.151.173');

      expect(rules, const <SingboxRule>[mandatory]);
    });

    test('rejects an API URL without a host', () {
      expect(MobileApiProxyRoute.ruleFor('not a URL'), isNull);
    });

    test('recognizes every path on the configured API origin', () {
      expect(
        MobileApiProxyRoute.requiresVpn(
          'https://api.example.com/api/v1/users/create?source=device',
          baseUrl: 'https://API.example.com',
        ),
        isTrue,
      );
      expect(
        MobileApiProxyRoute.requiresVpn('wss://api.example.com/ws/bind', baseUrl: 'https://api.example.com'),
        isTrue,
      );
    });

    test('does not capture a different host, port, or TLS mode', () {
      for (final url in <String>[
        'https://other.example.com/api/v1',
        'https://api.example.com:8443/api/v1',
        'http://api.example.com/api/v1',
      ]) {
        expect(MobileApiProxyRoute.requiresVpn(url, baseUrl: 'https://api.example.com'), isFalse, reason: url);
      }
    });

    test('uses the ordinary network for control-plane requests while VPN is unavailable', () async {
      final client = DioHttpClient(
        timeout: const Duration(milliseconds: 100),
        userAgent: 'test',
        debug: false,
        // Even a stale listener must not override the explicit disconnected
        // state supplied by the app.
        proxyProbe: (_, _) async => true,
      );
      client.setProxyPort(12334);
      client.setVpnActive(false);
      final url = Uri.parse(MobileApiProxyRoute.apiBaseUrl).resolve('/api/v1/test').toString();

      final route = await client.createAdaptiveHttpClient(url);
      expect(route.usesProxy, isFalse);
      route.client.close(force: true);
    });

    test('uses only the VPN proxy for control-plane requests while it is available', () async {
      final client = DioHttpClient(
        timeout: const Duration(milliseconds: 100),
        userAgent: 'test',
        debug: false,
        proxyProbe: (_, _) async => true,
      );
      client.setProxyPort(12334);
      client.setVpnActive(true);
      final url = Uri.parse(MobileApiProxyRoute.apiBaseUrl).resolve('/api/v1/test').toString();

      final route = await client.createAdaptiveHttpClient(url);
      expect(route.usesProxy, isTrue);
      route.client.close(force: true);
    });

    test('does not fall back to direct while VPN state is active but its proxy is unavailable', () async {
      final client = DioHttpClient(
        timeout: const Duration(milliseconds: 100),
        userAgent: 'test',
        debug: false,
        proxyProbe: (_, _) async => false,
      );
      client.setProxyPort(12334);
      client.setVpnActive(true);
      final url = Uri.parse(MobileApiProxyRoute.apiBaseUrl).resolve('/api/v1/test').toString();

      await expectLater(client.createAdaptiveHttpClient(url), throwsA(isA<VpnProxyUnavailableException>()));
    });

    test('offers VPN recovery for network failures but not HTTP responses', () async {
      var recoveryCalls = 0;
      final client = DioHttpClient(
        timeout: const Duration(milliseconds: 100),
        userAgent: 'test',
        debug: false,
        controlPlaneMatcher: (_) => true,
        requestVpnRecovery: () async {
          recoveryCalls++;
          return true;
        },
      );
      final request = RequestOptions(path: 'https://api.example.com/test');

      expect(
        await client.recoverWithVpnAfterFailure(
          request.path,
          DioException(requestOptions: request, type: DioExceptionType.connectionError),
        ),
        isTrue,
      );
      expect(
        await client.recoverWithVpnAfterFailure(
          request.path,
          DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: request, statusCode: 503),
          ),
        ),
        isFalse,
      );
      expect(recoveryCalls, 1);
    });
  });
}
