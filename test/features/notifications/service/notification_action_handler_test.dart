import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/notifications/service/notification_action_handler.dart';

void main() {
  group('NotificationActionHandler', () {
    test('allows only supported safe action_url schemes', () {
      final handler = NotificationActionHandler();

      expect(handler.isAllowed('https://zeon.example/path'), isTrue);
      expect(handler.isAllowed('zeon://notifications/test'), isTrue);
      expect(handler.isAllowed('http://zeon.example/path'), isFalse);
      expect(handler.isAllowed('file:///C:/Windows/System32/cmd.exe'), isFalse);
      expect(handler.isAllowed('cmd.exe /c calc'), isFalse);
    });

    test('rejects overlong action_url values', () {
      final handler = NotificationActionHandler();
      final longUrl = 'https://zeon.example/${'a' * (NotificationActionHandler.maxActionUrlLength + 1)}';

      expect(handler.isAllowed(longUrl), isFalse);
    });
  });
}
