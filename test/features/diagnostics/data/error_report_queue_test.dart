import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/diagnostics/data/error_report_queue.dart';

void main() {
  test('serializes concurrent enqueue operations', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final queue = ErrorReportQueue(preferences: preferences);

    await Future.wait(
      List.generate(5, (index) {
        return queue.enqueue({'event_id': 'event-$index', 'trigger': 'test'});
      }),
    );

    final dueReports = queue.dueReports(DateTime.now().toUtc());
    expect(
      dueReports.map((entry) => entry.eventId),
      containsAll(['event-0', 'event-1', 'event-2', 'event-3', 'event-4']),
    );
  });
}
