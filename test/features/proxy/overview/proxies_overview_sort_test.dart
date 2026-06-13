import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

void main() {
  OutboundInfo proxy(
    String tag, {
    int delay = 0,
    int combined = 0,
    String combinedLevel = "",
    int speed = 0,
    int quality = 0,
    String qualityLevel = "",
    bool isGroup = false,
    String tagDisplay = "",
  }) {
    return OutboundInfo(
      tag: tag,
      tagDisplay: tagDisplay,
      urlTestDelay: delay,
      combinedHealthScore: combined,
      combinedHealthLevel: combinedLevel,
      speedScore: speed,
      qualityScore: quality,
      qualityLevel: qualityLevel,
      isGroup: isGroup,
    );
  }

  test("sorts stronger combined health above lower ping", () {
    final items = sortProxyItemsByCombinedHealth([
      proxy("Russia7", delay: 29, combined: 61, combinedLevel: "medium"),
      proxy("Poland5", delay: 45, combined: 80, combinedLevel: "good"),
    ]);

    expect(items.map((e) => e.tag), ["Poland5", "Russia7"]);
  });

  test("orders health buckets before unknown and bad", () {
    final items = sortProxyItemsByCombinedHealth([
      proxy("bad", delay: 20, combined: 10, combinedLevel: "bad"),
      proxy("unknown", delay: 10),
      proxy("weak", delay: 30, combined: 30, combinedLevel: "weak"),
      proxy("medium", delay: 40, combined: 55, combinedLevel: "medium"),
      proxy("good", delay: 50, combined: 78, combinedLevel: "good"),
    ]);

    expect(items.map((e) => e.tag), ["good", "medium", "weak", "unknown", "bad"]);
  });

  test("uses speed score, quality score, and delay as tie breakers", () {
    final speedItems = sortProxyItemsByCombinedHealth([
      proxy("speed70", delay: 40, combined: 80, combinedLevel: "good", speed: 70, quality: 80),
      proxy("speed90", delay: 60, combined: 80, combinedLevel: "good", speed: 90, quality: 80),
    ]);
    expect(speedItems.map((e) => e.tag), ["speed90", "speed70"]);

    final qualityItems = sortProxyItemsByCombinedHealth([
      proxy("quality70", delay: 40, combined: 80, combinedLevel: "good", speed: 90, quality: 70),
      proxy("quality90", delay: 60, combined: 80, combinedLevel: "good", speed: 90, quality: 90),
    ]);
    expect(qualityItems.map((e) => e.tag), ["quality90", "quality70"]);

    final delayItems = sortProxyItemsByCombinedHealth([
      proxy("delay60", delay: 60, combined: 80, combinedLevel: "good", speed: 90, quality: 90),
      proxy("delay30", delay: 30, combined: 80, combinedLevel: "good", speed: 90, quality: 90),
    ]);
    expect(delayItems.map((e) => e.tag), ["delay30", "delay60"]);
  });

  test("keeps original order when values are identical", () {
    final items = sortProxyItemsByCombinedHealth([
      proxy("first", delay: 42, combined: 80, combinedLevel: "good", speed: 70, quality: 80),
      proxy("second", delay: 42, combined: 80, combinedLevel: "good", speed: 70, quality: 80),
      proxy("third", delay: 42, combined: 80, combinedLevel: "good", speed: 70, quality: 80),
    ]);

    expect(items.map((e) => e.tag), ["first", "second", "third"]);
  });

  test("keeps auto selection above regular servers", () {
    final items = sortProxyItemsByCombinedHealth([
      proxy("Poland5", delay: 45, combined: 95, combinedLevel: "excellent"),
      proxy("balance", combinedLevel: "unknown", isGroup: true),
      proxy("Russia7", delay: 29, combined: 61, combinedLevel: "medium"),
    ]);

    expect(items.map((e) => e.tag), ["balance", "Poland5", "Russia7"]);
  });

  test("does not rewrite manual server tags", () {
    final items = sortProxyItemsByCombinedHealth([
      proxy("Russia7", delay: 29, combined: 61, combinedLevel: "medium"),
      proxy("Poland5", delay: 45, combined: 80, combinedLevel: "good"),
    ]);

    expect(items[0].tag, "Poland5");
    expect(items[1].tag, "Russia7");
  });
}
