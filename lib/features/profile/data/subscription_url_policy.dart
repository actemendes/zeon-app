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
