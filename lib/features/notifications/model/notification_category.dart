enum NotificationCategory {
  alert('alert'),
  system('system'),
  promotion('promotion'),
  news('news');

  const NotificationCategory(this.wireName);

  final String wireName;

  static NotificationCategory? tryParse(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    for (final category in values) {
      if (category.wireName == normalized) return category;
    }
    return null;
  }
}
