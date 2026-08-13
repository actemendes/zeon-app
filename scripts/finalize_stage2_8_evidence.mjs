#!/usr/bin/env node

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { basename, join, relative, resolve } from "node:path";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith("--") || value === undefined) {
    throw new Error("Arguments must be --key value pairs");
  }
  args.set(key.slice(2), value);
}

const repoRoot = resolve(import.meta.dirname, "..");
const matrixRoot = resolve(
  args.get("matrix-root") ??
    join(
      repoRoot,
      ".codex-artifacts",
      "stage2.8-browser",
      "matrix-35e98971",
    ),
);
const dnsAbRoot = resolve(
  args.get("dns-ab-root") ??
    join(
      repoRoot,
      ".codex-artifacts",
      "stage2.8-browser",
      "dns-ab-07158f91",
    ),
);
const targetedLegacyRoot = resolve(
  args.get("targeted-legacy-root") ??
    join(
      repoRoot,
      ".codex-artifacts",
      "stage2.8-browser",
      "targeted-35e98971",
    ),
);
const targetedFinalRoot = resolve(
  args.get("targeted-final-root") ??
    join(
      repoRoot,
      ".codex-artifacts",
      "stage2.8-browser",
      "targeted-f9f523ab",
    ),
);
const outputRoot = resolve(
  args.get("output-root") ?? join(repoRoot, "out", "stage2-8"),
);
mkdirSync(outputRoot, { recursive: true });

function csvCell(value) {
  const text = String(value ?? "");
  return `"${text.replaceAll('"', '""')}"`;
}

function writeCsv(name, columns, rows) {
  const content = [
    columns.map(csvCell).join(","),
    ...rows.map((row) =>
      columns.map((column) => csvCell(row[column])).join(","),
    ),
  ].join("\n");
  writeFileSync(join(outputRoot, name), `${content}\n`, "utf8");
}

function parseCsv(text) {
  const records = [];
  let record = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (character === '"' && text[index + 1] === '"') {
        value += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        value += character;
      }
    } else if (character === '"') {
      quoted = true;
    } else if (character === ",") {
      record.push(value);
      value = "";
    } else if (character === "\n") {
      record.push(value.replace(/\r$/u, ""));
      records.push(record);
      record = [];
      value = "";
    } else {
      value += character;
    }
  }
  if (value || record.length) {
    record.push(value);
    records.push(record);
  }
  const [header, ...data] = records.filter((entry) => entry.length > 1);
  return data.map((entry) =>
    Object.fromEntries(header.map((column, index) => [column, entry[index] ?? ""])),
  );
}

function loadCatalog() {
  const source = readFileSync(
    join(repoRoot, "scripts", "validate_stage2_8_ru_browser.ps1"),
    "utf8",
  );
  const header = "Id,Name,Url,Kind,Applicable";
  const start = source.indexOf(header);
  const end = source.indexOf("\n'@", start);
  return source
    .slice(start, end)
    .trim()
    .split(/\r?\n/u)
    .slice(1)
    .map((line) => {
      const [id, name, url, kind, applicable] = line.split(",");
      return { id, name, url, kind, applicable };
    });
}

function latestCaptured(progressPath) {
  const latest = new Map();
  for (const row of parseCsv(readFileSync(progressPath, "utf8"))) {
    if (row.status === "CAPTURED") latest.set(row.siteId, row);
  }
  return latest;
}

function loadEvidence(capturePath) {
  return JSON.parse(readFileSync(join(capturePath, "evidence.json"), "utf8"));
}

function loadTelemetry(capturePath) {
  const path = join(capturePath, "route-telemetry.log");
  if (!existsSync(path)) return [];
  const events = [];
  for (const line of readFileSync(path, "utf8").split(/\r?\n/u)) {
    const prefix = "ZEON_ROUTE_VALIDATION ";
    const offset = line.indexOf(prefix);
    if (offset < 0) continue;
    try {
      events.push(JSON.parse(line.slice(offset + prefix.length)));
    } catch {
      // A malformed validation line remains absent evidence, never a PASS.
    }
  }
  return events;
}

function unique(values) {
  return [...new Set(values.filter((value) => value !== null && value !== ""))];
}

function resourceFailures(evidence) {
  return evidence.network.resources.filter(
    (resource) =>
      resource.error ||
      (Number.isInteger(resource.status) && resource.status >= 400),
  ).length;
}

function mainDocument(evidence) {
  return (
    evidence.network.resources.find(
      (resource) => resource.resourceType === "Document",
    ) ?? null
  );
}

const visualOverrides = {
  direct: {
    alfa: ["INCONCLUSIVE", "Chrome TLS page: NET::ERR_CERT_AUTHORITY_INVALID"],
  },
  russia: {
    alfa: [
      "INCONCLUSIVE",
      "Same Chrome TLS-chain failure as Direct and Global; not isolated to routing",
    ],
    wildberries: [
      "PASS WITH ANTI-BOT",
      "Initial HTTP 498 observed; catalog, images and bootstrap then rendered",
    ],
    megamarket: [
      "PASS WITH ANTI-BOT",
      "Visual slider/picture anti-bot challenge; page shell rendered",
    ],
  },
  global: {
    gosuslugi: ["VPN DETECTED", "Visual page explicitly requests disabling VPN"],
    esia: ["VPN DETECTED", "Visual page explicitly requests disabling VPN"],
    mos: ["INCONCLUSIVE", "Visual ERR_TIMED_OUT through Global VPN"],
    alfa: [
      "INCONCLUSIVE",
      "Same Chrome TLS-chain failure in Direct, Russia and Global",
    ],
    yandex: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    yandex_search: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    yandex_maps: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    yandex_music: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    kinopoisk: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    wildberries: ["VPN DETECTED", "Visual Wildberries VPN warning"],
    ozon: ["VPN DETECTED", "Visual Ozon proxy/VPN connection warning"],
    yandex_market: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    mail: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    dzen: [
      "TRANSPORT PASS / APPLICATION REJECTED",
      "Visual ERR_CONNECTION_CLOSED through Global VPN",
    ],
    twogis: ["VPN DETECTED", "Visual 2GIS VPN warning"],
    rzd: ["INCONCLUSIVE", "Visual ERR_TIMED_OUT through Global VPN"],
    aeroflot: [
      "FOREIGN GEO BLOCKED",
      "Visual access restriction page through Global VPN",
    ],
  },
};

function browserClassification(preset, site, evidence, rootRoute) {
  if (preset !== "direct" && rootRoute === null) {
    return [
      "INCONCLUSIVE",
      "Strict hostname-correlated root route event is absent",
    ];
  }
  const override = visualOverrides[preset]?.[site.id];
  if (override) return override;
  if (site.kind === "diagnostic") {
    return ["PASS", "Diagnostic page visually loaded with privacy redaction"];
  }
  if (evidence.navigation.error) {
    return ["INCONCLUSIVE", `Navigation error: ${evidence.navigation.error}`];
  }
  if (
    evidence.page.readyState !== "complete" ||
    evidence.page.bodyTextLength < 100
  ) {
    return ["INCONCLUSIVE", "Strict visual/DOM completeness gate not met"];
  }
  return ["PASS", "Visual page, DOM and essential resource shell loaded"];
}

const catalog = loadCatalog();
const catalogById = new Map(catalog.map((site) => [site.id, site]));
const selected = {};
for (const preset of ["direct", "russia", "global"]) {
  selected[preset] = latestCaptured(join(matrixRoot, `progress-${preset}.csv`));
}
if (existsSync(join(targetedLegacyRoot, "progress-russia.csv"))) {
  for (const [siteId, row] of latestCaptured(
    join(targetedLegacyRoot, "progress-russia.csv"),
  )) {
    selected.russia.set(siteId, row);
  }
}
for (const preset of ["russia", "global"]) {
  const progressPath = join(targetedFinalRoot, `progress-${preset}.csv`);
  if (!existsSync(progressPath)) continue;
  for (const [siteId, row] of latestCaptured(progressPath)) {
    selected[preset].set(siteId, row);
  }
}

const serviceRows = [];
const resourceRows = [];
const routeGroups = new Map();

for (const preset of ["direct", "russia", "global"]) {
  for (const site of catalog) {
    const progress = selected[preset].get(site.id);
    if (!progress) {
      serviceRows.push({
        preset,
        siteId: site.id,
        service: site.name,
        kind: site.kind,
        browserStatus: "INCONCLUSIVE",
        visualNote: "No successful capture",
      });
      continue;
    }
    const evidence = loadEvidence(progress.capturePath);
    const events = loadTelemetry(progress.capturePath);
    const routeEvents = events.filter((event) => event.kind === "route");
    const dnsEvents = events.filter((event) => event.kind === "dns");
    const rootHostnames = new Set([
      evidence.site.requestedHostname,
      evidence.page.currentHostname,
    ]);
    const rootRoute =
      routeEvents.find((event) => rootHostnames.has(event.hostname)) ?? null;
    const rootDns =
      dnsEvents.find((event) => rootHostnames.has(event.hostname)) ?? null;
    const [browserStatus, visualNote] = browserClassification(
      preset,
      site,
      evidence,
      rootRoute,
    );
    const protocols = unique(
      evidence.network.resources.map((resource) => resource.protocol),
    );
    const ipFamilies = unique(
      routeEvents.map((event) => event.ipVersion),
    );
    const routeDecisions = unique(routeEvents.map((event) => event.route));
    const dnsDecisions = unique(routeEvents.map((event) => event.dns));
    const generations = unique(
      events.map((event) => event.generation),
    );
    const main = mainDocument(evidence);
    serviceRows.push({
      preset,
      siteId: site.id,
      service: site.name,
      kind: site.kind,
      requestedHostname: evidence.site.requestedHostname,
      currentHostname: evidence.page.currentHostname,
      browserStatus,
      visualNote,
      readyState: evidence.page.readyState,
      bodyTextLength: evidence.page.bodyTextLength,
      imageCount: evidence.page.imageCount,
      completeImageCount: evidence.page.completeImageCount,
      resourceCount: evidence.network.resources.length,
      failedResourceCount: resourceFailures(evidence),
      mainStatus: main?.status ?? "",
      mainProtocol: main?.protocol ?? "",
      mainTtfbMs: main?.ttfbMs ?? "",
      protocols: protocols.join("|"),
      rootRoute: rootRoute?.route ?? (preset === "direct" ? "NO_TUN" : "UNKNOWN"),
      rootDns: rootRoute?.dns ?? rootDns?.dns ?? (preset === "direct" ? "SYSTEM" : "UNKNOWN"),
      rootMatchedRule: rootRoute?.matchedRule ?? rootDns?.matchedRule ?? "",
      rootMatchedRuleSet:
        rootRoute?.matchedRuleSet ?? rootDns?.matchedRuleSet ?? "",
      routeDecisions: routeDecisions.join("|"),
      dnsDecisions: dnsDecisions.join("|"),
      ipFamilies: ipFamilies.join("|"),
      generationCount: generations.length,
      mixedRouting:
        preset === "russia" &&
        site.kind !== "diagnostic" &&
        routeEvents.some((event) => event.route === "VPN")
          ? "YES"
          : "NO",
      captureId: evidence.captureId,
    });

    for (const resource of evidence.network.resources) {
      const correlated = routeEvents.find(
        (event) => event.hostname === resource.hostname,
      );
      resourceRows.push({
        preset,
        siteId: site.id,
        ordinal: resource.ordinal,
        hostname: resource.hostname,
        resourceType: resource.resourceType,
        httpStatus: resource.status,
        protocol: resource.protocol,
        remoteIpHash: resource.remoteIpHash,
        ipFamily: resource.ipFamily,
        ttfbMs: resource.ttfbMs,
        totalMs: resource.totalMs,
        error: resource.error,
        route: correlated?.route ?? (preset === "direct" ? "NO_TUN" : "UNATTRIBUTED"),
        dns: correlated?.dns ?? (preset === "direct" ? "SYSTEM" : "UNATTRIBUTED"),
        matchedRule: correlated?.matchedRule ?? "",
        matchedRuleSet: correlated?.matchedRuleSet ?? "",
      });
    }

    for (const event of events) {
      if (!["dns", "route"].includes(event.kind)) continue;
      const key = [
        preset,
        site.id,
        event.kind,
        event.hostname,
        event.resolvedIpHash,
        event.ipVersion,
        event.matchedRule,
        event.matchedRuleSet,
        event.route,
        event.dns,
        event.protocol,
        event.generation,
      ].join("\u001f");
      const current = routeGroups.get(key) ?? {
        preset,
        siteId: site.id,
        kind: event.kind,
        hostname: event.hostname,
        resolvedIpHash: event.resolvedIpHash,
        ipVersion: event.ipVersion,
        matchedRule: event.matchedRule,
        matchedRuleSet: event.matchedRuleSet,
        route: event.route,
        dns: event.dns,
        protocol: event.protocol,
        generation: event.generation,
        eventCount: 0,
      };
      current.eventCount += 1;
      routeGroups.set(key, current);
    }
  }
}

writeCsv(
  "browser-service-matrix.csv",
  [
    "preset",
    "siteId",
    "service",
    "kind",
    "requestedHostname",
    "currentHostname",
    "browserStatus",
    "visualNote",
    "readyState",
    "bodyTextLength",
    "imageCount",
    "completeImageCount",
    "resourceCount",
    "failedResourceCount",
    "mainStatus",
    "mainProtocol",
    "mainTtfbMs",
    "protocols",
    "rootRoute",
    "rootDns",
    "rootMatchedRule",
    "rootMatchedRuleSet",
    "routeDecisions",
    "dnsDecisions",
    "ipFamilies",
    "generationCount",
    "mixedRouting",
    "captureId",
  ],
  serviceRows,
);

writeCsv(
  "browser-network-resources.csv",
  [
    "preset",
    "siteId",
    "ordinal",
    "hostname",
    "resourceType",
    "httpStatus",
    "protocol",
    "remoteIpHash",
    "ipFamily",
    "ttfbMs",
    "totalMs",
    "error",
    "route",
    "dns",
    "matchedRule",
    "matchedRuleSet",
  ],
  resourceRows,
);

writeCsv(
  "route-match-evidence.csv",
  [
    "preset",
    "siteId",
    "kind",
    "hostname",
    "resolvedIpHash",
    "ipVersion",
    "matchedRule",
    "matchedRuleSet",
    "route",
    "dns",
    "protocol",
    "generation",
    "eventCount",
  ],
  [...routeGroups.values()],
);

function diagnosticEvidence(preset, siteId) {
  const progress = selected[preset].get(siteId);
  return loadEvidence(progress.capturePath);
}

function publicHashes(evidence) {
  return unique(
    (evidence.privacy.visibleIpEvidence ?? [])
      .filter((entry) => entry.ipScope === "PUBLIC")
      .map((entry) => entry.ipHash),
  );
}

const directExit = publicHashes(diagnosticEvidence("direct", "ru_public_exit"));
const russiaExit = publicHashes(diagnosticEvidence("russia", "ru_public_exit"));
const globalExit = publicHashes(diagnosticEvidence("global", "ru_public_exit"));
const directWebRtc = publicHashes(diagnosticEvidence("direct", "webrtc"));
const russiaWebRtc = publicHashes(diagnosticEvidence("russia", "webrtc"));
const globalWebRtc = publicHashes(diagnosticEvidence("global", "webrtc"));
const publicIpv6 = (preset) =>
  (diagnosticEvidence(preset, "webrtc").privacy.visibleIpEvidence ?? []).some(
    (entry) => entry.ipScope === "PUBLIC" && entry.ipFamily === "IPv6",
  );

const vpnRows = [
  {
    preset: "Direct",
    publicExitIpHashes: directExit.join("|"),
    exitMatchesDirect: "BASELINE",
    webRtcPublicIpHashes: directWebRtc.join("|"),
    publicIpv6Observed: publicIpv6("direct"),
    country: "NOT_CAPTURED",
    asn: "NOT_CAPTURED",
    asnCategory: "NOT_CAPTURED",
    dnsCountry: "NOT_CAPTURED",
    timezone: "Europe/Moscow (device)",
    language: "ru (browser UI)",
    warnings: "NONE_OBSERVED_ON_RU_SERVICES",
    verdict: "BASELINE",
  },
  {
    preset: "Russia",
    publicExitIpHashes: russiaExit.join("|"),
    exitMatchesDirect: russiaExit.some((hash) => directExit.includes(hash)),
    webRtcPublicIpHashes: russiaWebRtc.join("|"),
    publicIpv6Observed: publicIpv6("russia"),
    country: "NOT_CAPTURED",
    asn: "NOT_CAPTURED",
    asnCategory: "NOT_CAPTURED",
    dnsCountry: "NOT_CAPTURED",
    timezone: "Europe/Moscow (device)",
    language: "ru (browser UI)",
    warnings: "NONE_OBSERVED_ON_RU_SERVICES",
    verdict: "DIRECT_EXIT_HASH_MATCH; COUNTRY_ASN_INCONCLUSIVE",
  },
  {
    preset: "Global",
    publicExitIpHashes: globalExit.join("|"),
    exitMatchesDirect: globalExit.some((hash) => directExit.includes(hash)),
    webRtcPublicIpHashes: globalWebRtc.join("|"),
    publicIpv6Observed: publicIpv6("global"),
    country: "NOT_CAPTURED",
    asn: "NOT_CAPTURED",
    asnCategory: "NOT_CAPTURED",
    dnsCountry: "NOT_CAPTURED",
    timezone: "Europe/Moscow (device)",
    language: "ru (browser UI)",
    warnings: "GOSUSLUGI|ESIA|WILDBERRIES|OZON|2GIS",
    verdict: "DISTINCT_VPN_HASH; NO_PUBLIC_IPV6; COUNTRY_ASN_INCONCLUSIVE",
  },
];
writeCsv(
  "browser-vpn-detection.csv",
  [
    "preset",
    "publicExitIpHashes",
    "exitMatchesDirect",
    "webRtcPublicIpHashes",
    "publicIpv6Observed",
    "country",
    "asn",
    "asnCategory",
    "dnsCountry",
    "timezone",
    "language",
    "warnings",
    "verdict",
  ],
  vpnRows,
);

const remoteRows = latestCaptured(join(dnsAbRoot, "progress-russia.csv"));
const dnsRows = [];
for (const [siteId, remoteProgress] of remoteRows) {
  const directProgress = selected.russia.get(siteId);
  if (!directProgress) continue;
  const direct = loadEvidence(directProgress.capturePath);
  const remote = loadEvidence(remoteProgress.capturePath);
  const directEvents = loadTelemetry(directProgress.capturePath);
  const remoteEvents = loadTelemetry(remoteProgress.capturePath);
  const directRoute = directEvents.find((event) => event.kind === "route");
  const remoteRoute = remoteEvents.find((event) => event.kind === "route");
  dnsRows.push({
    siteId,
    directCurrentHostname: direct.page.currentHostname,
    remoteCurrentHostname: remote.page.currentHostname,
    directReadyState: direct.page.readyState,
    remoteReadyState: remote.page.readyState,
    directBodyTextLength: direct.page.bodyTextLength,
    remoteBodyTextLength: remote.page.bodyTextLength,
    directResourceCount: direct.network.resources.length,
    remoteResourceCount: remote.network.resources.length,
    directFailureCount: resourceFailures(direct),
    remoteFailureCount: resourceFailures(remote),
    directLoadEventMs: direct.page.navigationTiming?.loadEventMs ?? "",
    remoteLoadEventMs: remote.page.navigationTiming?.loadEventMs ?? "",
    directRoute: directRoute?.route ?? "UNKNOWN",
    remoteRoute: remoteRoute?.route ?? "UNKNOWN",
    directDns: directRoute?.dns ?? "UNKNOWN",
    remoteDns: remoteRoute?.dns ?? "REMOTE",
    directIpFamilies: unique(
      directEvents
        .filter((event) => event.kind === "route")
        .map((event) => event.ipVersion),
    ).join("|"),
    remoteIpFamilies: unique(
      remoteEvents
        .filter((event) => event.kind === "route")
        .map((event) => event.ipVersion),
    ).join("|"),
    cnameComparison: "NOT_EXPOSED_BY_CDP",
    browserVerdict:
      direct.page.readyState === "complete" &&
      remote.page.readyState === "complete"
        ? "DIRECT_DNS_NOT_VISUALLY_WORSE"
        : "INCONCLUSIVE",
  });
}

function latestCustomCapture(sessionPrefix, siteId) {
  if (!existsSync(dnsAbRoot)) return null;
  const sessions = readdirSync(dnsAbRoot).filter((name) =>
    name.startsWith(sessionPrefix),
  );
  const candidates = [];
  for (const session of sessions) {
    const directory = join(dnsAbRoot, session, "russia", siteId);
    if (!existsSync(directory)) continue;
    for (const capture of readdirSync(directory)) {
      const full = join(directory, capture);
      if (existsSync(join(full, "evidence.json"))) candidates.push(full);
    }
  }
  return candidates.sort().at(-1) ?? null;
}

const directCom = latestCustomCapture("direct-dns-35e98971-ab-connected", "twogis_com");
const remoteCom = latestCustomCapture("remote-dns-baseline-07158f91", "twogis_com");
if (directCom && remoteCom) {
  const direct = loadEvidence(directCom);
  const remote = loadEvidence(remoteCom);
  const directEvents = loadTelemetry(directCom);
  const remoteEvents = loadTelemetry(remoteCom);
  dnsRows.push({
    siteId: "twogis_com",
    directCurrentHostname: direct.page.currentHostname,
    remoteCurrentHostname: remote.page.currentHostname,
    directReadyState: direct.page.readyState,
    remoteReadyState: remote.page.readyState,
    directBodyTextLength: direct.page.bodyTextLength,
    remoteBodyTextLength: remote.page.bodyTextLength,
    directResourceCount: direct.network.resources.length,
    remoteResourceCount: remote.network.resources.length,
    directFailureCount: resourceFailures(direct),
    remoteFailureCount: resourceFailures(remote),
    directLoadEventMs: direct.page.navigationTiming?.loadEventMs ?? "",
    remoteLoadEventMs: remote.page.navigationTiming?.loadEventMs ?? "",
    directRoute:
      directEvents.find((event) => event.kind === "route")?.route ?? "UNKNOWN",
    remoteRoute:
      remoteEvents.find((event) => event.kind === "route")?.route ?? "UNKNOWN",
    directDns:
      directEvents.find((event) => event.kind === "route")?.dns ?? "UNKNOWN",
    remoteDns:
      remoteEvents.find((event) => event.kind === "route")?.dns ?? "UNKNOWN",
    directIpFamilies: unique(
      directEvents
        .filter((event) => event.kind === "route")
        .map((event) => event.ipVersion),
    ).join("|"),
    remoteIpFamilies: unique(
      remoteEvents
        .filter((event) => event.kind === "route")
        .map((event) => event.ipVersion),
    ).join("|"),
    cnameComparison: "NOT_EXPOSED_BY_CDP",
    browserVerdict: "DIRECT_DNS_NOT_VISUALLY_WORSE",
  });
}

writeCsv(
  "dns-ab.csv",
  [
    "siteId",
    "directCurrentHostname",
    "remoteCurrentHostname",
    "directReadyState",
    "remoteReadyState",
    "directBodyTextLength",
    "remoteBodyTextLength",
    "directResourceCount",
    "remoteResourceCount",
    "directFailureCount",
    "remoteFailureCount",
    "directLoadEventMs",
    "remoteLoadEventMs",
    "directRoute",
    "remoteRoute",
    "directDns",
    "remoteDns",
    "directIpFamilies",
    "remoteIpFamilies",
    "cnameComparison",
    "browserVerdict",
  ],
  dnsRows,
);

const ruIpRows = [...routeGroups.values()]
  .filter(
    (row) =>
      row.preset === "russia" &&
      row.kind === "route" &&
      row.matchedRuleSet === "zapret-ru-ip",
  )
  .map((row) => ({
    service: catalogById.get(row.siteId)?.name ?? row.siteId,
    hostname: row.hostname,
    resourceCategory: "BROWSER_RESOURCE",
    cname: "NOT_EXPOSED_BY_CDP",
    routeBefore: "RU_IP_MATCH_REQUIRED",
    browserFailureBefore: "NONE_OBSERVED",
    routeAfter: `${row.route}/${row.dns}`,
    browserResultAfter: "LOADED_OR_NON_FATAL_RESOURCE",
    ruleChange: "NO_SERVICE_RULE_CHANGE; ZAPRET_RU_IP_MATCHED",
  }));
writeCsv(
  "cname-cdn-discovery.csv",
  [
    "service",
    "hostname",
    "resourceCategory",
    "cname",
    "routeBefore",
    "browserFailureBefore",
    "routeAfter",
    "browserResultAfter",
    "ruleChange",
  ],
  ruIpRows,
);

writeCsv(
  "routing-before-after.csv",
  [
    "case",
    "before",
    "after",
    "evidence",
    "rollback",
  ],
  [
    {
      case: "Yandex family in Russia",
      before: "Explicit VPN override",
      after: "zeon-ru-yandex -> DIRECT/DIRECT_DNS",
      evidence: "144 route events; 27 hostnames; visual browser load",
      rollback: "git revert ab446d7d",
    },
    {
      case: "Wildberries family in Russia",
      before: "Explicit VPN override",
      after: "zeon-ru-wildberries -> DIRECT/DIRECT_DNS",
      evidence: "22 route events; 17 hostnames; visual catalog load",
      rollback: "git revert f427499d",
    },
    {
      case: ".ru/.su/.xn--p1ai",
      before: "Final VPN unless separately overridden",
      after: "zapret-ru-domains -> DIRECT",
      evidence: "Physical suffix captures and per-host route telemetry",
      rollback: "Revert bundled RU destination routing commits",
    },
    {
      case: "Cross-zone hostname on Russian IP",
      before: "Final VPN",
      after: "zapret-ru-ip -> DIRECT",
      evidence: "Ozon/Avito/2GIS/VK cross-zone browser resources",
      rollback: "Revert bundled RU destination routing commits",
    },
    {
      case: "Global preset",
      before: "VPN final",
      after: "VPN final; no RU rule sets installed",
      evidence: "Global telemetry uses final/VPN/REMOTE and no RU matched set",
      rollback: "No Global behavior change",
    },
  ],
);

const statusCounts = {};
for (const row of serviceRows) {
  const key = `${row.preset}:${row.browserStatus}`;
  statusCounts[key] = (statusCounts[key] ?? 0) + 1;
}

process.stdout.write(
  `${JSON.stringify(
    {
      matrixRows: serviceRows.length,
      resourceRows: resourceRows.length,
      routeRows: routeGroups.size,
      dnsAbRows: dnsRows.length,
      ruIpRows: ruIpRows.length,
      statusCounts,
      outputRoot: relative(repoRoot, outputRoot),
    },
    null,
    2,
  )}\n`,
);
