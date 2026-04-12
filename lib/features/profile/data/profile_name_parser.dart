String parseProfileName(String? value) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty) {
    return '';
  }

  final hasSeparator = raw.contains('|');
  final withoutPrefix = hasSeparator ? raw.split('|').skip(1).join('|').trim() : raw;
  final normalized = withoutPrefix.replaceAll('|', ' ').replaceAll('_', ' ');
  return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
}
