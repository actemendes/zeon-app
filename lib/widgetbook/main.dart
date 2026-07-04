import 'package:flutter/widgets.dart';
import 'package:zeon/widgetbook/widgetbook.dart';
import 'package:zeon/widgetbook/widgetbook_context.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  widgetbookSharedPreferences = await SharedPreferences.getInstance();

  runApp(const ZeonWidgetbook());
}
