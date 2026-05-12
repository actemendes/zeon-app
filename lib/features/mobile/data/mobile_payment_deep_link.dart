const mobilePaymentResultDeepLinkScheme = 'zeon';
const legacyMobilePaymentResultDeepLinkScheme = 'hiddify';
const mobilePaymentResultDeepLinkHost = 'payment-result';
const mobilePaymentResultDeepLinkBase = '$mobilePaymentResultDeepLinkScheme://$mobilePaymentResultDeepLinkHost';

String? extractPaymentSessionIdFromDeepLink(String rawUrl) {
  final input = rawUrl.trim();
  if (input.isEmpty) return null;
  final uri = Uri.tryParse(input);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != mobilePaymentResultDeepLinkScheme && scheme != legacyMobilePaymentResultDeepLinkScheme) return null;
  final host = uri.host.toLowerCase();
  final firstPath = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first.toLowerCase();
  if (host != mobilePaymentResultDeepLinkHost && firstPath != mobilePaymentResultDeepLinkHost) return null;
  final sid = uri.queryParameters['sid']?.trim();
  if (sid == null || sid.isEmpty) return null;
  return sid;
}
