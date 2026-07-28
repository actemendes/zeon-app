import 'dart:io';

final Stopwatch _vpnProcessClock = Stopwatch()..start();

String vpnDiagnosticEvent(
  String name,
  int generation, {
  String details = "",
}) {
  final suffix = details.trim().isEmpty ? "" : " ${details.trim()}";
  return "event=$name monotonic_ms=${_vpnProcessClock.elapsedMilliseconds} "
      "pid=$pid generation=$generation$suffix";
}

String selectorDiagnosticDetails(String line) {
  const allowed = <String>{
    "type",
    "reason",
    "old_id",
    "new_id",
    "interrupt_external",
    "closed_tcp",
    "closed_udp",
    "closed_external",
    "full_core_restart",
  };
  final fields = <String>[];
  for (final match in RegExp(r"([a-z_]+)=([A-Za-z0-9_.-]+)").allMatches(line)) {
    final key = match.group(1);
    final value = match.group(2);
    if (key != null && value != null && allowed.contains(key)) {
      fields.add("$key=$value");
    }
  }
  return fields.join(" ");
}
