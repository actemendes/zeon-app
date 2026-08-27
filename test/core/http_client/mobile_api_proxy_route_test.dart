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
        isWindows: false,
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
        isWindows: false,
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
        isWindows: false,
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

    group('Windows route matrix', () {
      const controlPlaneUrl = 'https://api.example.com/control';
      const ordinaryUrl = 'https://example.org/data';

      DioHttpClient client({required bool proxyReady, bool? vpnActive}) {
        final result = DioHttpClient(
          timeout: const Duration(milliseconds: 100),
          userAgent: 'test',
          debug: false,
          isWindows: true,
          controlPlaneMatcher: (url) => url == controlPlaneUrl,
          proxyProbe: (host, port) async {
            expect(host, DioHttpClient.localZeonProxyHost);
            expect(port, 12334);
            return proxyReady;
          },
        );
        result.setProxyPort(12334);
        if (vpnActive != null) result.setVpnActive(vpnActive);
        return result;
      }

      for (final vpnState in <bool?>[false, true, null]) {
        final label = vpnState == null
            ? 'unknown'
            : vpnState
            ? 'connected'
            : 'disconnected';

        test('proxyOnly wins for control-plane and ordinary URLs when VPN is $label', () async {
          final http = client(proxyReady: true, vpnActive: vpnState);
          for (final url in <String>[controlPlaneUrl, ordinaryUrl]) {
            expect(await http.resolveRouteForTesting(url: url, proxyOnly: true), HttpRouteMode.localZeonProxy);
          }
        });

        test('directOnly excludes the ZEON proxy when VPN is $label', () async {
          final http = client(proxyReady: true, vpnActive: vpnState);
          for (final url in <String>[controlPlaneUrl, ordinaryUrl]) {
            expect(await http.resolveRouteForTesting(url: url, directOnly: true), HttpRouteMode.systemNetwork);
          }
        });
      }

      test('proxyOnly never falls back when ZEON proxy is unavailable', () async {
        final http = client(proxyReady: false, vpnActive: false);
        await expectLater(
          http.resolveRouteForTesting(url: controlPlaneUrl, proxyOnly: true),
          throwsA(isA<VpnProxyUnavailableException>()),
        );
      });

      test('conflicting explicit routes are rejected', () async {
        final http = client(proxyReady: true, vpnActive: true);
        await expectLater(
          http.resolveRouteForTesting(url: controlPlaneUrl, directOnly: true, proxyOnly: true),
          throwsArgumentError,
        );
      });

      test('control-plane and adaptive traffic use system network while disconnected', () async {
        final http = client(proxyReady: true, vpnActive: false);
        expect(await http.resolveRouteForTesting(url: controlPlaneUrl), HttpRouteMode.systemNetwork);
        expect(await http.resolveRouteForTesting(url: ordinaryUrl), HttpRouteMode.systemNetwork);
      });

      test('control-plane and adaptive traffic use ZEON proxy only while connected and ready', () async {
        final http = client(proxyReady: true, vpnActive: true);
        expect(await http.resolveRouteForTesting(url: controlPlaneUrl), HttpRouteMode.localZeonProxy);
        expect(await http.resolveRouteForTesting(url: ordinaryUrl), HttpRouteMode.localZeonProxy);
      });

      test('unknown startup state does not probe or use a loopback listener on Windows', () async {
        var probes = 0;
        final http = DioHttpClient(
          timeout: const Duration(milliseconds: 100),
          userAgent: 'test',
          debug: false,
          isWindows: true,
          controlPlaneMatcher: (_) => true,
          proxyProbe: (_, _) async {
            probes++;
            return true;
          },
        )..setProxyPort(12334);

        expect(await http.resolveRouteForTesting(url: controlPlaneUrl), HttpRouteMode.systemNetwork);
        expect(probes, 0);
      });
    });
  });
}
