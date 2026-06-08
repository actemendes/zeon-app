enum NotificationPriority {
  low('low'),
  normal('normal'),
  high('high'),
  critical('critical');

  const NotificationPriority(this.wireName);

  final String wireName;

  static NotificationPriority? tryParse(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    for (final priority in values) {
      if (priority.wireName == normalized) return priority;
    }
    return null;
  }
}
