const legacyZeonProfileHost = "130.49.151.173";
const canonicalZeonProfileHost = "api.zeon-vps.online";

/// Migrates only ZEON's known pre-domain profile origin.
///
/// URI replacement preserves the original scheme, explicit port, path, query,
/// and fragment. Invalid/relative URLs retain the existing trimmed-input
/// contract and are left unchanged.
String canonicalizeZeonProfileUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.toLowerCase() != legacyZeonProfileHost) {
    return trimmed;
  }
  return uri.replace(host: canonicalZeonProfileHost).toString();
}

String enforceZeonSingBoxSubscriptionUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !(uri.scheme == "http" || uri.scheme == "https")) {
    return trimmed;
  }

  final path = uri.path.toLowerCase();
  if (!path.startsWith("/.netlify/functions/subscription/")) {
    return trimmed;
  }

  final query = Map<String, String>.from(uri.queryParameters)
    ..["format"] = "sing-box"
    ..["client"] = "zeon";
  return uri.replace(queryParameters: query).toString();
}
