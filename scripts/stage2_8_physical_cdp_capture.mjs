#!/usr/bin/env node

/**
 * Privacy-preserving physical-browser evidence capture for ZEON Stage 2.8.
 *
 * Safety invariants:
 * - Microsoft Edge for Android only (com.microsoft.emmx).
 * - ADB forwards only localabstract:chrome_devtools_remote.
 * - HTTP discovery uses only /json/version.
 * - A fresh dispose-on-detach browser context and one exact target are created.
 * - The script never enumerates browser targets or reads existing tabs.
 * - URLs are reduced to hostnames before persistence.
 * - Remote IPs and console text are reduced to ephemeral capture-scoped HMACs.
 * - The exact target, context, WebSocket, and ADB forward are closed in finally.
 * - Evidence is capture-only and never assigns PASS/FAIL.
 *
 * Requires Node.js 22+ and an operator-started Edge instance with remote
 * debugging available on chrome_devtools_remote.
 */

import { execFileSync } from "node:child_process";
import {
  createHash,
  createHmac,
  randomBytes,
  randomUUID,
} from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  open,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import http from "node:http";
import { isIP } from "node:net";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

export const EDGE_PACKAGE = "com.microsoft.emmx";
export const EDGE_LAUNCHER_COMPONENT =
  "com.microsoft.emmx/com.microsoft.ruby.Main";
export const DEVTOOLS_SOCKET = "localabstract:chrome_devtools_remote";
export const VERSION_ENDPOINT = "/json/version";
export const EVIDENCE_SCHEMA_VERSION = 1;

const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const SAFE_SERIAL = /^[A-Za-z0-9._:-]{1,128}$/;
const SAFE_ERROR = /(?:^|[^A-Z0-9_])(net::ERR_[A-Z0-9_]+)(?:$|[^A-Z0-9_])/;
const ALLOWED_PRESETS = new Set(["Direct", "Russia", "Global"]);
const ALLOWED_KINDS = new Set(["service", "diagnostic"]);
const ALLOWED_RESOURCE_TYPES = new Set([
  "Document",
  "Stylesheet",
  "Image",
  "Media",
  "Font",
  "Script",
  "TextTrack",
  "XHR",
  "Fetch",
  "Prefetch",
  "EventSource",
  "WebSocket",
  "Manifest",
  "SignedExchange",
  "Ping",
  "CSPViolationReport",
  "Preflight",
  "Other",
]);
const ALLOWED_PROTOCOLS = new Set([
  "http/0.9",
  "http/1.0",
  "http/1.1",
  "h2",
  "h3",
  "quic",
  "websocket",
]);
const ALLOWED_CONSOLE_TYPES = new Set([
  "log",
  "debug",
  "info",
  "error",
  "warning",
  "dir",
  "dirxml",
  "table",
  "trace",
  "clear",
  "startGroup",
  "startGroupCollapsed",
  "endGroup",
  "assert",
  "profile",
  "profileEnd",
  "count",
  "timeEnd",
]);
const ALLOWED_LOG_SOURCES = new Set([
  "xml",
  "javascript",
  "network",
  "storage",
  "appcache",
  "rendering",
  "security",
  "deprecation",
  "worker",
  "violation",
  "intervention",
  "recommendation",
  "other",
]);
const ALLOWED_LOG_LEVELS = new Set(["verbose", "info", "warning", "error"]);

export class CaptureError extends Error {
  constructor(code, safeMessage) {
    super(safeMessage);
    this.name = "CaptureError";
    this.code = code;
  }
}

export function parseArgs(argv) {
  const values = new Map();
  let help = false;
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--help" || token === "-h") {
      help = true;
      continue;
    }
    if (!token.startsWith("--")) {
      throw new CaptureError("CLI_ARGUMENT", "Arguments must use --name value form.");
    }
    const key = token.slice(2);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new CaptureError("CLI_ARGUMENT", `Missing value for --${key}.`);
    }
    if (values.has(key)) {
      throw new CaptureError("CLI_ARGUMENT", `Duplicate --${key}.`);
    }
    values.set(key, value);
    index += 1;
  }

  if (help) return { help: true };

  const required = ["site-id", "url", "preset", "session", "serial", "kind"];
  for (const key of required) {
    if (!values.has(key)) {
      throw new CaptureError("CLI_ARGUMENT", `Missing required --${key}.`);
    }
  }

  const allowed = new Set([
    ...required,
    "adb",
    "output-root",
    "settle-ms",
    "navigation-timeout-ms",
    "max-resources",
    "max-console",
    "hmac-key-file",
  ]);
  for (const key of values.keys()) {
    if (!allowed.has(key)) {
      throw new CaptureError("CLI_ARGUMENT", `Unknown option --${key}.`);
    }
  }

  const siteId = validateId(values.get("site-id"), "site-id");
  const session = validateId(values.get("session"), "session");
  const serial = values.get("serial");
  if (!SAFE_SERIAL.test(serial)) {
    throw new CaptureError("CLI_ARGUMENT", "serial has unsupported characters.");
  }
  const preset = values.get("preset");
  if (!ALLOWED_PRESETS.has(preset)) {
    throw new CaptureError("CLI_ARGUMENT", "preset must be Direct, Russia, or Global.");
  }
  const kind = values.get("kind");
  if (!ALLOWED_KINDS.has(kind)) {
    throw new CaptureError("CLI_ARGUMENT", "kind must be service or diagnostic.");
  }
  let targetUrl;
  try {
    targetUrl = new URL(values.get("url"));
  } catch {
    throw new CaptureError("CLI_ARGUMENT", "url must be a valid HTTPS URL.");
  }
  if (targetUrl.protocol !== "https:" || targetUrl.username || targetUrl.password) {
    throw new CaptureError("CLI_ARGUMENT", "url must be HTTPS and must not contain credentials.");
  }

  return {
    help: false,
    siteId,
    targetUrl,
    preset,
    session,
    serial,
    kind,
    adb: values.get("adb") ?? process.env.ADB ?? "adb",
    outputRoot: path.resolve(values.get("output-root") ?? "out/stage2-8/physical-cdp"),
    hmacKeyFile: values.has("hmac-key-file")
      ? path.resolve(values.get("hmac-key-file"))
      : null,
    settleMs: parseBoundedInteger(values.get("settle-ms") ?? "15000", "settle-ms", 0, 60000),
    navigationTimeoutMs: parseBoundedInteger(
      values.get("navigation-timeout-ms") ?? "45000",
      "navigation-timeout-ms",
      1000,
      60000,
    ),
    maxResources: parseBoundedInteger(
      values.get("max-resources") ?? "5000",
      "max-resources",
      1,
      20000,
    ),
    maxConsole: parseBoundedInteger(
      values.get("max-console") ?? "1000",
      "max-console",
      0,
      5000,
    ),
  };
}

function validateId(value, label) {
  if (!SAFE_ID.test(value)) {
    throw new CaptureError("CLI_ARGUMENT", `${label} has unsupported characters.`);
  }
  return value;
}

function parseBoundedInteger(value, label, minimum, maximum) {
  if (!/^\d+$/.test(value)) {
    throw new CaptureError("CLI_ARGUMENT", `${label} must be an integer.`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new CaptureError("CLI_ARGUMENT", `${label} must be between ${minimum} and ${maximum}.`);
  }
  return parsed;
}

export function hostnameOnly(value) {
  try {
    return new URL(value).hostname.toLowerCase().replace(/\.$/, "") || null;
  } catch {
    return null;
  }
}

export function destinationIdentity(rawHostname, hmacKey) {
  if (typeof rawHostname !== "string" || rawHostname.length === 0) {
    return {
      hostname: null,
      hostnameIpHash: null,
      hostnameIpFamily: "UNKNOWN",
      hostnameIpScope: "UNKNOWN",
    };
  }
  const family = classifyIpFamily(rawHostname);
  if (family !== "UNKNOWN") {
    return {
      hostname: null,
      hostnameIpHash: hmacSensitive(
        rawHostname.toLowerCase(),
        hmacKey,
        "hostname-ip-literal",
      ),
      hostnameIpFamily: family,
      hostnameIpScope: classifyIpScope(rawHostname),
    };
  }
  return {
    hostname: rawHostname.toLowerCase().replace(/\.$/, ""),
    hostnameIpHash: null,
    hostnameIpFamily: "UNKNOWN",
    hostnameIpScope: "UNKNOWN",
  };
}

export function classifyIpFamily(rawAddress) {
  const candidate = normalizeIpAddress(rawAddress);
  if (!candidate) return "UNKNOWN";
  const family = isIP(candidate);
  if (family === 4) return "IPv4";
  if (family === 6) return "IPv6";
  return "UNKNOWN";
}

function normalizeIpAddress(rawAddress) {
  if (typeof rawAddress !== "string") return null;
  let candidate = rawAddress.trim();
  if (candidate.startsWith("[") && candidate.includes("]")) {
    candidate = candidate.slice(1, candidate.indexOf("]"));
  }
  const zoneIndex = candidate.indexOf("%");
  if (zoneIndex >= 0) candidate = candidate.slice(0, zoneIndex);
  return isIP(candidate) ? candidate.toLowerCase() : null;
}

export function classifyIpScope(rawAddress) {
  const candidate = normalizeIpAddress(rawAddress);
  if (!candidate) return "UNKNOWN";
  if (isIP(candidate) === 4) {
    const octets = candidate.split(".").map(Number);
    const [a, b, c] = octets;
    if (octets.every((part) => part === 0)) return "UNSPECIFIED";
    if (a === 127) return "LOOPBACK";
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) {
      return "PRIVATE";
    }
    if (a === 169 && b === 254) return "LINK_LOCAL";
    if (a === 100 && b >= 64 && b <= 127) return "SHARED_CGNAT";
    if (
      (a === 192 && b === 0 && c === 2) ||
      (a === 198 && b === 51 && c === 100) ||
      (a === 203 && b === 0 && c === 113)
    ) {
      return "DOCUMENTATION";
    }
    if (a >= 224 && a <= 239) return "MULTICAST";
    if (a >= 240) return "RESERVED";
    return "PUBLIC";
  }
  if (candidate === "::") return "UNSPECIFIED";
  if (candidate === "::1") return "LOOPBACK";
  if (/^f[cd][0-9a-f]{2}:/i.test(candidate)) return "PRIVATE";
  if (/^fe[89ab][0-9a-f]:/i.test(candidate)) return "LINK_LOCAL";
  if (/^ff[0-9a-f]{2}:/i.test(candidate)) return "MULTICAST";
  if (/^2001:db8(?::|$)/i.test(candidate)) return "DOCUMENTATION";
  return "PUBLIC";
}

export function hmacSensitive(value, hmacKey, namespace) {
  if (typeof value !== "string" || value.length === 0) return null;
  return `hmac-sha256:${createHmac("sha256", hmacKey)
    .update(namespace)
    .update("\0")
    .update(value)
    .digest("hex")}`;
}

export function stableHashScopeId(hmacKey) {
  return `sha256:${createHash("sha256")
    .update("zeon-stage2.8-physical-cdp-hash-scope-v1")
    .update("\0")
    .update(hmacKey)
    .digest("hex")}`;
}

export async function loadOrCreateHmacKey(filePath) {
  await mkdir(path.dirname(filePath), { recursive: true });
  let created = false;
  try {
    const handle = await open(filePath, "wx", 0o600);
    created = true;
    const generated = randomBytes(32);
    try {
      await handle.writeFile(generated);
    } finally {
      generated.fill(0);
      await handle.close();
    }
  } catch (error) {
    if (error?.code !== "EEXIST") {
      if (created) await rm(filePath, { force: true }).catch(() => {});
      throw new CaptureError(
        "HMAC_KEY_FILE",
        "Unable to create the private HMAC session key.",
      );
    }
  }
  await chmod(filePath, 0o600).catch(() => {
    // Windows ACLs do not map cleanly to POSIX mode bits; the key remains
    // local and its path/value are never serialized or logged.
  });
  let metadata;
  let bytes;
  try {
    metadata = await lstat(filePath);
    if (!metadata.isFile() || metadata.isSymbolicLink()) {
      throw new Error("not a regular file");
    }
    bytes = await readFile(filePath);
  } catch {
    throw new CaptureError(
      "HMAC_KEY_FILE",
      "Unable to read the private HMAC session key.",
    );
  }
  if (bytes.length !== 32) {
    bytes.fill(0);
    throw new CaptureError(
      "HMAC_KEY_FILE",
      "The HMAC session key must contain exactly 32 binary bytes.",
    );
  }
  return bytes;
}

export function hashRemoteAddress(rawAddress, hmacKey) {
  const normalized = normalizeIpAddress(rawAddress);
  const family = classifyIpFamily(normalized);
  if (family === "UNKNOWN") {
    return {
      remoteIpHash: null,
      ipFamily: "UNKNOWN",
      ipScope: "UNKNOWN",
    };
  }
  return {
    remoteIpHash: hmacSensitive(normalized, hmacKey, "remote-ip"),
    ipFamily: family,
    ipScope: classifyIpScope(normalized),
  };
}

export function hashVisibleIpLiteral(rawAddress, hmacKey) {
  const normalized = normalizeIpAddress(rawAddress);
  const family = classifyIpFamily(normalized);
  if (family === "UNKNOWN") return null;
  return {
    ipHash: hmacSensitive(normalized, hmacKey, "visible-ip"),
    ipFamily: family,
    ipScope: classifyIpScope(normalized),
  };
}

export function sanitizeResourceType(value) {
  return ALLOWED_RESOURCE_TYPES.has(value) ? value : "Other";
}

export function sanitizeProtocol(value) {
  if (typeof value !== "string") return "UNKNOWN";
  const normalized = value.toLowerCase();
  return ALLOWED_PROTOCOLS.has(normalized) ? normalized : "UNKNOWN";
}

export function sanitizeStatus(value) {
  return Number.isInteger(value) && value >= 100 && value <= 599 ? value : null;
}

export function sanitizeNetworkError(value) {
  if (typeof value !== "string") return "OTHER";
  return value.match(SAFE_ERROR)?.[1] ?? "OTHER";
}

export function safeDuration(end, start = 0) {
  if (!Number.isFinite(end) || !Number.isFinite(start)) return null;
  const duration = end - start;
  if (duration < 0 || duration > 600000) return null;
  return Math.round(duration * 100) / 100;
}

export function sanitizeResponseTiming(timing) {
  if (!timing || typeof timing !== "object") return null;
  return {
    dnsMs: safeDuration(timing.dnsEnd, timing.dnsStart),
    connectMs: safeDuration(timing.connectEnd, timing.connectStart),
    sslMs: safeDuration(timing.sslEnd, timing.sslStart),
    sendMs: safeDuration(timing.sendEnd, timing.sendStart),
    receiveHeadersMs: safeDuration(timing.receiveHeadersEnd, timing.sendEnd),
  };
}

function safeEnum(value, allowed, fallback) {
  return typeof value === "string" && allowed.has(value) ? value : fallback;
}

function boundedHashInput(value) {
  if (typeof value === "string") return value.slice(0, 8192);
  if (typeof value === "number" || typeof value === "boolean" || value === null) {
    return String(value);
  }
  return "";
}

export function sanitizeConsoleCall(params, hmacKey, relativeMs) {
  const rawParts = [];
  for (const arg of Array.isArray(params?.args) ? params.args.slice(0, 32) : []) {
    rawParts.push(boundedHashInput(arg?.value ?? arg?.description ?? arg?.type ?? ""));
  }
  return {
    event: "console",
    level: safeEnum(params?.type, ALLOWED_CONSOLE_TYPES, "other"),
    relativeMs: safeDuration(relativeMs),
    argumentCount: Array.isArray(params?.args) ? params.args.length : 0,
    messageHash: hmacSensitive(rawParts.join("\u241f"), hmacKey, "console"),
  };
}

export function sanitizeException(params, hmacKey, relativeMs) {
  const details = params?.exceptionDetails ?? {};
  const raw = boundedHashInput(
    details?.exception?.description ??
      details?.exception?.value ??
      details?.text ??
      "exception",
  );
  const className =
    typeof details?.exception?.className === "string" &&
    /^[A-Za-z_$][A-Za-z0-9_$]{0,79}$/.test(details.exception.className)
      ? details.exception.className
      : null;
  return {
    event: "exception",
    level: "error",
    relativeMs: safeDuration(relativeMs),
    className,
    messageHash: hmacSensitive(raw, hmacKey, "console"),
  };
}

export function sanitizeLogEntry(params, hmacKey, relativeMs) {
  const entry = params?.entry ?? {};
  return {
    event: "log",
    source: safeEnum(entry.source, ALLOWED_LOG_SOURCES, "other"),
    level: safeEnum(entry.level, ALLOWED_LOG_LEVELS, "info"),
    relativeMs: safeDuration(relativeMs),
    messageHash: hmacSensitive(
      boundedHashInput(entry.text ?? "log"),
      hmacKey,
      "console",
    ),
  };
}

export function sanitizeBlockedReason(value) {
  if (
    typeof value === "string" &&
    /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(value)
  ) {
    return value;
  }
  return null;
}

export class EvidenceRecorder {
  constructor({
    hmacKey,
    maxResources = 5000,
    maxConsole = 1000,
  }) {
    this.hmacKey = hmacKey;
    this.firstConsoleTimestamp = null;
    this.maxResources = maxResources;
    this.maxConsole = maxConsole;
    this.resources = [];
    this.console = [];
    this.activeRequests = new Map();
    this.nextOrdinal = 1;
    this.droppedResources = 0;
    this.droppedConsole = 0;
  }

  relativeMs(timestampSeconds) {
    if (!Number.isFinite(timestampSeconds)) return null;
    if (this.firstConsoleTimestamp === null) {
      this.firstConsoleTimestamp = timestampSeconds;
    }
    return safeDuration(timestampSeconds * 1000, this.firstConsoleTimestamp * 1000);
  }

  startRequest(requestId, params, resourceTypeOverride = null) {
    const rawHostname = hostnameOnly(params?.request?.url ?? params?.url);
    if (!rawHostname) return null;
    const destination = destinationIdentity(rawHostname, this.hmacKey);
    if (this.resources.length >= this.maxResources) {
      this.droppedResources += 1;
      return null;
    }
    const record = {
      ordinal: this.nextOrdinal,
      hostname: destination.hostname,
      hostnameIpHash: destination.hostnameIpHash,
      hostnameIpFamily: destination.hostnameIpFamily,
      resourceType: sanitizeResourceType(
        resourceTypeOverride ?? params?.type ?? "Other",
      ),
      status: null,
      protocol: "UNKNOWN",
      remoteIpHash: null,
      ipFamily: "UNKNOWN",
      ipScope: "UNKNOWN",
      timing: null,
      ttfbMs: null,
      totalMs: null,
      error: null,
      blockedReason: null,
    };
    this.nextOrdinal += 1;
    this.resources.push(record);
    this.activeRequests.set(requestId, {
      record,
      startedAt: params?.timestamp,
    });
    return record;
  }

  onRequestWillBeSent(params) {
    if (params?.redirectResponse) {
      this.applyResponse(
        params.requestId,
        params.redirectResponse,
        params.timestamp,
      );
      this.finishRequest(params.requestId, params.timestamp);
    }
    this.startRequest(params?.requestId, params);
  }

  applyResponse(requestId, response, timestamp) {
    const active = this.activeRequests.get(requestId);
    if (!active) return;
    const address = hashRemoteAddress(response?.remoteIPAddress, this.hmacKey);
    active.record.status = sanitizeStatus(response?.status);
    active.record.protocol = sanitizeProtocol(response?.protocol);
    active.record.remoteIpHash = address.remoteIpHash;
    active.record.ipFamily = address.ipFamily;
    active.record.ipScope = address.ipScope;
    active.record.timing = sanitizeResponseTiming(response?.timing);
    active.record.ttfbMs =
      Number.isFinite(timestamp) && Number.isFinite(active.startedAt)
        ? safeDuration(timestamp * 1000, active.startedAt * 1000)
        : null;
  }

  onResponseReceived(params) {
    this.applyResponse(
      params?.requestId,
      params?.response,
      params?.timestamp,
    );
  }

  finishRequest(requestId, timestamp) {
    const active = this.activeRequests.get(requestId);
    if (!active) return;
    active.record.totalMs =
      Number.isFinite(timestamp) && Number.isFinite(active.startedAt)
        ? safeDuration(timestamp * 1000, active.startedAt * 1000)
        : null;
    this.activeRequests.delete(requestId);
  }

  onLoadingFinished(params) {
    this.finishRequest(params?.requestId, params?.timestamp);
  }

  onLoadingFailed(params) {
    const active = this.activeRequests.get(params?.requestId);
    if (!active) return;
    active.record.error = sanitizeNetworkError(params?.errorText);
    active.record.blockedReason = sanitizeBlockedReason(params?.blockedReason);
    this.finishRequest(params?.requestId, params?.timestamp);
  }

  onWebSocketCreated(params) {
    if (this.activeRequests.has(params?.requestId)) return;
    this.startRequest(params?.requestId, params, "WebSocket");
  }

  onWebSocketHandshakeResponse(params) {
    const active = this.activeRequests.get(params?.requestId);
    if (!active) return;
    active.record.status = sanitizeStatus(params?.response?.status) ?? 101;
    active.record.protocol = "websocket";
  }

  addConsole(event) {
    if (this.console.length >= this.maxConsole) {
      this.droppedConsole += 1;
      return;
    }
    this.console.push(event);
  }

  onConsoleCall(params) {
    this.addConsole(
      sanitizeConsoleCall(
        params,
        this.hmacKey,
        this.relativeMs(params?.timestamp),
      ),
    );
  }

  onException(params) {
    this.addConsole(
      sanitizeException(
        params,
        this.hmacKey,
        this.relativeMs(params?.timestamp),
      ),
    );
  }

  onLogEntry(params) {
    this.addConsole(
      sanitizeLogEntry(
        params,
        this.hmacKey,
        this.relativeMs(params?.entry?.timestamp),
      ),
    );
  }
}

export function assertSanitizedEvidence(value) {
  const forbiddenKeys = new Set([
    "url",
    "path",
    "query",
    "headers",
    "cookies",
    "body",
    "remoteIPAddress",
    "remotePort",
    "userAgent",
  ]);
  const walk = (current) => {
    if (Array.isArray(current)) {
      for (const entry of current) walk(entry);
      return;
    }
    if (!current || typeof current !== "object") return;
    for (const [key, nested] of Object.entries(current)) {
      if (forbiddenKeys.has(key)) {
        throw new CaptureError(
          "PRIVACY_ASSERTION",
          `Forbidden evidence field: ${key}.`,
        );
      }
      walk(nested);
    }
  };
  walk(value);
}

function runAdb(adb, args, options = {}) {
  try {
    return execFileSync(adb, args, {
      encoding: options.binary ? null : "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: options.timeout ?? 15000,
      maxBuffer: options.maxBuffer ?? 1024 * 1024,
      windowsHide: true,
    });
  } catch {
    throw new CaptureError(
      options.errorCode ?? "ADB_COMMAND",
      options.safeMessage ?? "ADB command failed.",
    );
  }
}

export function parseAdbDevices(output) {
  const devices = [];
  for (const rawLine of String(output).split(/\r?\n/).slice(1)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("*")) continue;
    const match = line.match(/^(\S+)\s+(\S+)(?:\s+(.*))?$/);
    if (!match) continue;
    devices.push({
      serial: match[1],
      state: match[2],
      details: match[3] ?? "",
    });
  }
  return devices;
}

function preflightDevice(options) {
  const output = runAdb(options.adb, ["devices", "-l"], {
    errorCode: "ADB_DEVICES",
    safeMessage: "Unable to list ADB devices.",
  });
  const devices = parseAdbDevices(output);
  if (devices.some((device) => device.state === "unauthorized")) {
    throw new CaptureError(
      "ADB_UNAUTHORIZED",
      "Authorize ADB on the phone screen; do not bypass the device lock.",
    );
  }
  const authorized = devices.filter((device) => device.state === "device");
  if (
    devices.length !== 1 ||
    authorized.length !== 1 ||
    authorized[0].serial !== options.serial
  ) {
    throw new CaptureError(
      "ADB_DEVICE_SET",
      "Exactly the requested single authorized physical device is required.",
    );
  }
  const prefix = ["-s", options.serial];
  const model = runAdb(options.adb, [
    ...prefix,
    "shell",
    "getprop",
    "ro.product.model",
  ]).trim();
  if (model !== "GM1901") {
    throw new CaptureError(
      "ADB_MODEL",
      "The authorized device is not the expected OnePlus GM1901.",
    );
  }
  const sdk = runAdb(options.adb, [
    ...prefix,
    "shell",
    "getprop",
    "ro.build.version.sdk",
  ]).trim();
  if (sdk !== "36") {
    throw new CaptureError("ADB_SDK", "The device must run Android API 36.");
  }
  const packagePath = runAdb(options.adb, [
    ...prefix,
    "shell",
    "pm",
    "path",
    EDGE_PACKAGE,
  ]).trim();
  if (!packagePath.startsWith("package:")) {
    throw new CaptureError(
      "EDGE_MISSING",
      "Microsoft Edge for Android is not installed.",
    );
  }
}

function createForward(options) {
  const output = runAdb(
    options.adb,
    [
      "-s",
      options.serial,
      "forward",
      "tcp:0",
      DEVTOOLS_SOCKET,
    ],
    {
      errorCode: "ADB_FORWARD",
      safeMessage: "Unable to create the isolated DevTools ADB forward.",
    },
  ).trim();
  if (!/^\d{4,5}$/.test(output)) {
    throw new CaptureError(
      "ADB_FORWARD",
      "ADB did not return a valid local forward port.",
    );
  }
  return Number(output);
}

function removeForward(options, localPort) {
  if (!localPort) return true;
  try {
    execFileSync(
      options.adb,
      [
        "-s",
        options.serial,
        "forward",
        "--remove",
        `tcp:${localPort}`,
      ],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 15000,
        windowsHide: true,
      },
    );
    return true;
  } catch {
    return false;
  }
}

function wakeEdgeLauncher(options) {
  runAdb(
    options.adb,
    [
      "-s",
      options.serial,
      "shell",
      "am",
      "start",
      "-W",
      "-a",
      "android.intent.action.MAIN",
      "-c",
      "android.intent.category.LAUNCHER",
      "-n",
      EDGE_LAUNCHER_COMPONENT,
    ],
    {
      timeout: 15000,
      errorCode: "EDGE_WAKE",
      safeMessage: "Unable to resume Microsoft Edge with its explicit launcher.",
    },
  );
}

export function fetchVersionDocument(localPort, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const request = http.get(
      {
        hostname: "127.0.0.1",
        port: localPort,
        path: VERSION_ENDPOINT,
        method: "GET",
        headers: { Accept: "application/json" },
      },
      (response) => {
        if (response.statusCode !== 200) {
          response.resume();
          reject(
            new CaptureError(
              "CDP_VERSION",
              "DevTools version endpoint returned a non-success status.",
            ),
          );
          return;
        }
        const chunks = [];
        let length = 0;
        response.on("data", (chunk) => {
          length += chunk.length;
          if (length > 64 * 1024) {
            request.destroy(
              new CaptureError(
                "CDP_VERSION",
                "DevTools version response exceeded the privacy limit.",
              ),
            );
            return;
          }
          chunks.push(chunk);
        });
        response.on("end", () => {
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
          } catch {
            reject(
              new CaptureError(
                "CDP_VERSION",
                "DevTools version response was not valid JSON.",
              ),
            );
          }
        });
      },
    );
    request.setTimeout(timeoutMs, () => {
      request.destroy(
        new CaptureError(
          "CDP_VERSION_TIMEOUT",
          "DevTools version endpoint timed out.",
        ),
      );
    });
    request.on("error", (error) => reject(error));
  });
}

async function fetchVersionWithSafeWake(options, localPort) {
  try {
    return await fetchVersionDocument(localPort, 1500);
  } catch {
    wakeEdgeLauncher(options);
  }
  for (let attempt = 0; attempt < 10; attempt += 1) {
    await sleep(750);
    try {
      return await fetchVersionDocument(localPort, 1500);
    } catch {
      // Edge startup is bounded; no endpoint other than /json/version is used.
    }
  }
  throw new CaptureError(
    "EDGE_CDP_UNAVAILABLE",
    "Edge did not expose chrome_devtools_remote after the safe launcher wake-up.",
  );
}

export function localBrowserWebSocketUrl(versionDocument, localPort) {
  if (
    !versionDocument ||
    typeof versionDocument.webSocketDebuggerUrl !== "string"
  ) {
    throw new CaptureError(
      "CDP_VERSION",
      "DevTools version response omitted the browser WebSocket.",
    );
  }
  const parsed = new URL(versionDocument.webSocketDebuggerUrl);
  if (!["ws:", "wss:"].includes(parsed.protocol)) {
    throw new CaptureError(
      "CDP_VERSION",
      "DevTools returned an unsupported WebSocket scheme.",
    );
  }
  parsed.protocol = "ws:";
  parsed.hostname = "127.0.0.1";
  parsed.port = String(localPort);
  parsed.username = "";
  parsed.password = "";
  return parsed.toString();
}

class CdpConnection {
  constructor(webSocketUrl) {
    this.webSocketUrl = webSocketUrl;
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Set();
  }

  async connect(timeoutMs = 10000) {
    if (typeof WebSocket !== "function") {
      throw new CaptureError(
        "NODE_VERSION",
        "Node.js 22+ with the built-in WebSocket client is required.",
      );
    }
    const socket = new WebSocket(this.webSocketUrl);
    this.socket = socket;
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(
          new CaptureError(
            "CDP_CONNECT_TIMEOUT",
            "Browser WebSocket connection timed out.",
          ),
        );
        socket.close();
      }, timeoutMs);
      socket.addEventListener(
        "open",
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true },
      );
      socket.addEventListener(
        "error",
        () => {
          clearTimeout(timer);
          reject(
            new CaptureError(
              "CDP_CONNECT",
              "Browser WebSocket connection failed.",
            ),
          );
        },
        { once: true },
      );
    });
    socket.addEventListener("message", (event) => this.onMessage(event.data));
    socket.addEventListener("close", () => this.onClose());
  }

  onMessage(raw) {
    let message;
    try {
      message = JSON.parse(String(raw));
    } catch {
      return;
    }
    if (Number.isInteger(message.id)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(
          new CaptureError(
            "CDP_COMMAND",
            `CDP command ${pending.method} failed.`,
          ),
        );
      } else {
        pending.resolve(message.result ?? {});
      }
      return;
    }
    if (typeof message.method !== "string") return;
    for (const listener of this.listeners) {
      listener(message);
    }
  }

  onClose() {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(
        new CaptureError("CDP_CLOSED", "Browser WebSocket closed unexpectedly."),
      );
    }
    this.pending.clear();
  }

  onEvent(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  send(method, params = {}, sessionId = undefined, timeoutMs = 15000) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(
        new CaptureError("CDP_CLOSED", "Browser WebSocket is not open."),
      );
    }
    const id = this.nextId;
    this.nextId += 1;
    const message = { id, method, params };
    if (sessionId) message.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new CaptureError(
            "CDP_COMMAND_TIMEOUT",
            `CDP command ${method} timed out.`,
          ),
        );
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
      this.socket.send(JSON.stringify(message));
    });
  }

  async close() {
    if (!this.socket) return true;
    const socket = this.socket;
    this.socket = null;
    if (socket.readyState === WebSocket.CLOSED) return true;
    if (
      socket.readyState === WebSocket.OPEN ||
      socket.readyState === WebSocket.CONNECTING ||
      socket.readyState === WebSocket.CLOSING
    ) {
      return new Promise((resolve) => {
        const timer = setTimeout(() => resolve(false), 2000);
        socket.addEventListener(
          "close",
          () => {
            clearTimeout(timer);
            resolve(true);
          },
          { once: true },
        );
        if (
          socket.readyState === WebSocket.OPEN ||
          socket.readyState === WebSocket.CONNECTING
        ) {
          socket.close();
        }
      });
    }
    return false;
  }
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function createTargetEventWaiter(
  cdp,
  sessionId,
  method,
  timeoutMs,
  predicate = () => true,
) {
  let remove = () => {};
  let timer = null;
  const promise = new Promise((resolve, reject) => {
    timer = setTimeout(() => {
      remove();
      reject(
        new CaptureError(
          "CDP_EVENT_TIMEOUT",
          `Timed out waiting for ${method}.`,
        ),
      );
    }, timeoutMs);
    remove = cdp.onEvent((event) => {
      if (
        event.sessionId !== sessionId ||
        event.method !== method ||
        !predicate(event.params)
      ) {
        return;
      }
      clearTimeout(timer);
      remove();
      resolve(event.params ?? {});
    });
  });
  return {
    promise,
    cancel() {
      if (timer) clearTimeout(timer);
      remove();
    },
  };
}

function attachRecorder(cdp, sessionId, recorder) {
  return cdp.onEvent((event) => {
    if (event.sessionId !== sessionId) return;
    switch (event.method) {
      case "Network.requestWillBeSent":
        recorder.onRequestWillBeSent(event.params);
        break;
      case "Network.responseReceived":
        recorder.onResponseReceived(event.params);
        break;
      case "Network.loadingFinished":
        recorder.onLoadingFinished(event.params);
        break;
      case "Network.loadingFailed":
        recorder.onLoadingFailed(event.params);
        break;
      case "Network.webSocketCreated":
        recorder.onWebSocketCreated(event.params);
        break;
      case "Network.webSocketHandshakeResponseReceived":
        recorder.onWebSocketHandshakeResponse(event.params);
        break;
      case "Runtime.consoleAPICalled":
        recorder.onConsoleCall(event.params);
        break;
      case "Runtime.exceptionThrown":
        recorder.onException(event.params);
        break;
      case "Log.entryAdded":
        recorder.onLogEntry(event.params);
        break;
      default:
        break;
    }
  });
}

export const DOM_METRICS_EXPRESSION = String.raw`
(() => {
  const finite = (value) => Number.isFinite(value) ? Math.round(value * 100) / 100 : null;
  const visible = (element) => {
    const style = getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const elements = Array.from(document.querySelectorAll("*"));
  const images = Array.from(document.images);
  const navigation = performance.getEntriesByType("navigation")[0];
  return {
    readyState: ["loading", "interactive", "complete"].includes(document.readyState) ? document.readyState : "unknown",
    currentHostname: location.hostname.toLowerCase().replace(/\.$/, ""),
    domNodeCount: elements.length,
    visibleElementCount: elements.reduce((count, element) => count + (visible(element) ? 1 : 0), 0),
    bodyTextLength: document.body?.innerText?.length ?? 0,
    imageCount: images.length,
    completeImageCount: images.filter((image) => image.complete && image.naturalWidth > 0).length,
    scriptCount: document.scripts.length,
    stylesheetCount: document.styleSheets.length,
    frameCount: document.querySelectorAll("iframe").length,
    viewport: {
      width: innerWidth,
      height: innerHeight,
      devicePixelRatio: finite(devicePixelRatio),
      scrollWidth: document.documentElement?.scrollWidth ?? 0,
      scrollHeight: document.documentElement?.scrollHeight ?? 0,
    },
    navigationTiming: navigation ? {
      domInteractiveMs: finite(navigation.domInteractive),
      domContentLoadedMs: finite(navigation.domContentLoadedEventEnd),
      loadEventMs: finite(navigation.loadEventEnd),
      responseStartMs: finite(navigation.responseStart),
      durationMs: finite(navigation.duration),
    } : null,
  };
})()
`;

export const SCREENSHOT_IP_MASK_EXPRESSION = String.raw`
(() => {
  const replacement = "[REDACTED IP]";
  const maskedLiterals = new Set();
  const candidatePattern = /(?:\[[0-9A-Fa-f:.%]+\]|[0-9A-Fa-f](?:[0-9A-Fa-f:.%]{1,}[0-9A-Fa-f%]))/g;
  const ipv4Pattern = /(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})(?![0-9.])/g;

  const isIpv6 = (raw) => {
    let value = raw;
    if (value.startsWith("[") && value.endsWith("]")) value = value.slice(1, -1);
    const zone = value.indexOf("%");
    if (zone >= 0) value = value.slice(0, zone);
    if (!value.includes(":") || !/^[0-9A-Fa-f:.]+$/.test(value)) return false;
    const doubleColonParts = value.split("::");
    if (doubleColonParts.length > 2) return false;
    const parseSide = (side) => {
      if (!side) return [];
      const parts = side.split(":");
      for (let index = 0; index < parts.length; index += 1) {
        const part = parts[index];
        if (part.includes(".")) {
          if (index !== parts.length - 1) return null;
          const octets = part.split(".");
          if (octets.length !== 4 || octets.some((octet) => !/^[0-9]{1,3}$/.test(octet) || Number(octet) > 255)) {
            return null;
          }
        } else if (!/^[0-9A-Fa-f]{1,4}$/.test(part)) {
          return null;
        }
      }
      return parts;
    };
    const left = parseSide(doubleColonParts[0]);
    const right = parseSide(doubleColonParts[1] ?? "");
    if (!left || !right) return false;
    const groupCount = [...left, ...right].reduce((count, part) => count + (part.includes(".") ? 2 : 1), 0);
    return doubleColonParts.length === 2 ? groupCount < 8 : groupCount === 8;
  };

  const mask = (text) => {
    if (typeof text !== "string" || text.length === 0) return { value: text, count: 0 };
    let count = 0;
    let value = text.replace(ipv4Pattern, (match) => {
      if (maskedLiterals.size < 1024) maskedLiterals.add(match);
      count += 1;
      return replacement;
    });
    value = value.replace(candidatePattern, (candidate) => {
      if (!isIpv6(candidate)) return candidate;
      if (maskedLiterals.size < 1024) maskedLiterals.add(candidate);
      count += 1;
      return replacement;
    });
    return { value, count };
  };

  let masked = 0;
  let inaccessibleFrames = 0;
  const visitRoot = (root) => {
    const rootDocument = root.nodeType === Node.DOCUMENT_NODE ? root : root.ownerDocument ?? document;
    const walker = rootDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const node of nodes) {
      const parent = node.parentElement;
      if (parent && ["SCRIPT", "STYLE", "NOSCRIPT"].includes(parent.tagName)) continue;
      const result = mask(node.nodeValue);
      if (result.count > 0) {
        node.nodeValue = result.value;
        masked += result.count;
      }
    }
    for (const element of root.querySelectorAll?.("*") ?? []) {
      if (element.shadowRoot) visitRoot(element.shadowRoot);
      if (element.tagName === "INPUT" || element.tagName === "TEXTAREA") {
        const result = mask(element.value);
        if (result.count > 0) {
          element.value = result.value;
          masked += result.count;
        }
      }
    }
  };
  visitRoot(document);
  for (const frame of document.querySelectorAll("iframe")) {
    try {
      if (frame.contentDocument) visitRoot(frame.contentDocument);
      else inaccessibleFrames += 1;
    } catch {
      inaccessibleFrames += 1;
    }
  }

  const style = document.createElement("style");
  style.id = "zeon-cdp-privacy-redaction";
  style.textContent = [
    "input[type=password] { visibility: hidden !important; }",
    "iframe, canvas { filter: blur(32px) !important; }",
  ].join("\n");
  document.documentElement.appendChild(style);

  let remaining = 0;
  const countRoot = (root) => {
    const rootDocument = root.nodeType === Node.DOCUMENT_NODE ? root : root.ownerDocument ?? document;
    const walker = rootDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const parent = walker.currentNode.parentElement;
      if (parent && ["SCRIPT", "STYLE", "NOSCRIPT"].includes(parent.tagName)) continue;
      const text = walker.currentNode.nodeValue ?? "";
      if (ipv4Pattern.test(text)) remaining += 1;
      ipv4Pattern.lastIndex = 0;
      for (const candidate of text.match(candidatePattern) ?? []) {
        if (isIpv6(candidate)) remaining += 1;
      }
      candidatePattern.lastIndex = 0;
    }
    for (const element of root.querySelectorAll?.("*") ?? []) {
      if (element.shadowRoot) countRoot(element.shadowRoot);
    }
  };
  countRoot(document);
  for (const frame of document.querySelectorAll("iframe")) {
    try {
      if (frame.contentDocument) countRoot(frame.contentDocument);
    } catch {
      // Inaccessible frames are always blurred by the privacy stylesheet.
    }
  }

  return {
    applied: true,
    maskedIpLiteralCount: masked,
    maskedIpLiterals: Array.from(maskedLiterals),
    maskedIpLiteralsTruncated: maskedLiterals.size >= 1024,
    remainingIpLiteralCount: remaining,
    inaccessibleFrameCount: inaccessibleFrames,
  };
})()
`;

export const DIAGNOSTIC_BLUR_EXPRESSION = String.raw`
(() => {
  const style = document.createElement("style");
  style.id = "zeon-cdp-diagnostic-privacy-blur";
  style.textContent = [
    "body { filter: blur(32px) saturate(0.5) !important; }",
    "iframe, canvas, img, video, svg { filter: blur(40px) !important; }",
    "input, textarea { color: transparent !important; text-shadow: none !important; }",
  ].join("\n");
  document.documentElement.appendChild(style);
  return { applied: true };
})()
`;

async function evaluateValue(cdp, sessionId, expression) {
  const result = await cdp.send(
    "Runtime.evaluate",
    {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: false,
    },
    sessionId,
  );
  if (result?.exceptionDetails || !result?.result) {
    throw new CaptureError(
      "CDP_EVALUATE",
      "Privacy-preserving page evaluation failed.",
    );
  }
  return result.result.value;
}

function sanitizeDomMetrics(value, hmacKey) {
  const integer = (entry, maximum = 10_000_000) =>
    Number.isInteger(entry) && entry >= 0 && entry <= maximum ? entry : null;
  const duration = (entry) =>
    Number.isFinite(entry) && entry >= 0 && entry <= 600000
      ? Math.round(entry * 100) / 100
      : null;
  const viewport = value?.viewport ?? {};
  const timing = value?.navigationTiming;
  const destination = destinationIdentity(value?.currentHostname, hmacKey);
  return {
    readyState: ["loading", "interactive", "complete"].includes(
      value?.readyState,
    )
      ? value.readyState
      : "unknown",
    currentHostname:
      destination.hostname && destination.hostname.length <= 253
        ? destination.hostname
        : null,
    currentHostnameIpHash: destination.hostnameIpHash,
    currentHostnameIpFamily: destination.hostnameIpFamily,
    domNodeCount: integer(value?.domNodeCount),
    visibleElementCount: integer(value?.visibleElementCount),
    bodyTextLength: integer(value?.bodyTextLength, 100_000_000),
    imageCount: integer(value?.imageCount),
    completeImageCount: integer(value?.completeImageCount),
    scriptCount: integer(value?.scriptCount),
    stylesheetCount: integer(value?.stylesheetCount),
    frameCount: integer(value?.frameCount),
    viewport: {
      width: integer(viewport.width, 10000),
      height: integer(viewport.height, 10000),
      devicePixelRatio: duration(viewport.devicePixelRatio),
      scrollWidth: integer(viewport.scrollWidth, 1_000_000),
      scrollHeight: integer(viewport.scrollHeight, 10_000_000),
    },
    navigationTiming: timing
      ? {
          domInteractiveMs: duration(timing.domInteractiveMs),
          domContentLoadedMs: duration(timing.domContentLoadedMs),
          loadEventMs: duration(timing.loadEventMs),
          responseStartMs: duration(timing.responseStartMs),
          durationMs: duration(timing.durationMs),
        }
      : null,
  };
}

async function writeExclusive(filePath, data) {
  const handle = await open(filePath, "wx");
  try {
    await handle.writeFile(data);
  } finally {
    await handle.close();
  }
}

async function writeJsonAtomic(filePath, value) {
  const temporary = `${filePath}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: "utf8",
      flag: "wx",
    });
    await rename(temporary, filePath);
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}

function safeBrowserProduct(value) {
  if (typeof value !== "string") return "UNKNOWN";
  const match = value.match(/^([A-Za-z][A-Za-z0-9 ._-]{0,39})\/([0-9.]{1,39})$/);
  return match ? `${match[1]}/${match[2]}` : "UNKNOWN";
}

function safeProtocolVersion(value) {
  return typeof value === "string" && /^[0-9.]{1,16}$/.test(value)
    ? value
    : "UNKNOWN";
}

function utcArtifactStamp(date = new Date()) {
  return date
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
}

async function capture(options) {
  preflightDevice(options);

  const hmacKey = options.hmacKeyFile
    ? await loadOrCreateHmacKey(options.hmacKeyFile)
    : randomBytes(32);
  const hashScopeId = stableHashScopeId(hmacKey);
  const captureId = `${utcArtifactStamp()}-${randomBytes(4).toString("hex")}`;
  const captureDirectory = path.join(
    options.outputRoot,
    options.session,
    options.preset.toLowerCase(),
    options.siteId,
    captureId,
  );
  await mkdir(captureDirectory, { recursive: true });

  let localPort = null;
  let cdp = null;
  let browserContextId = null;
  let targetId = null;
  let targetSessionId = null;
  let removeRecorder = null;
  let screenshotWritten = false;
  try {
    localPort = createForward(options);
    const version = await fetchVersionWithSafeWake(options, localPort);
    if (
      typeof version["User-Agent"] !== "string" ||
      !/\bEdgA?\//.test(version["User-Agent"])
    ) {
      throw new CaptureError(
        "EDGE_IDENTITY",
        "The chrome_devtools_remote endpoint does not identify Microsoft Edge.",
      );
    }
    const webSocketUrl = localBrowserWebSocketUrl(version, localPort);
    cdp = new CdpConnection(webSocketUrl);
    await cdp.connect();

    let context;
    try {
      context = await cdp.send("Target.createBrowserContext", {
        disposeOnDetach: true,
      });
    } catch {
      throw new CaptureError(
        "CDP_CONTEXT_UNSUPPORTED",
        "Edge cannot create an isolated browser context; capture is INCONCLUSIVE and regular targets are forbidden.",
      );
    }
    browserContextId = context.browserContextId;
    if (typeof browserContextId !== "string" || !browserContextId) {
      throw new CaptureError(
        "CDP_CONTEXT",
        "Browser context creation did not return an identifier.",
      );
    }

    const target = await cdp.send("Target.createTarget", {
      url: "about:blank",
      browserContextId,
      newWindow: false,
      background: false,
    });
    targetId = target.targetId;
    if (typeof targetId !== "string" || !targetId) {
      throw new CaptureError(
        "CDP_TARGET",
        "Target creation did not return an identifier.",
      );
    }

    const attached = await cdp.send("Target.attachToTarget", {
      targetId,
      flatten: true,
    });
    targetSessionId = attached.sessionId;
    if (typeof targetSessionId !== "string" || !targetSessionId) {
      throw new CaptureError(
        "CDP_TARGET",
        "Exact target attachment did not return a session.",
      );
    }

    await Promise.all([
      cdp.send("Page.enable", {}, targetSessionId),
      cdp.send(
        "Network.enable",
        {
          maxTotalBufferSize: 10 * 1024 * 1024,
          maxResourceBufferSize: 1024 * 1024,
          maxPostDataSize: 0,
        },
        targetSessionId,
      ),
      cdp.send("Runtime.enable", {}, targetSessionId),
      cdp.send("Log.enable", {}, targetSessionId),
      cdp.send(
        "Page.setLifecycleEventsEnabled",
        { enabled: true },
        targetSessionId,
      ),
    ]);

    const recorder = new EvidenceRecorder({
      hmacKey,
      maxResources: options.maxResources,
      maxConsole: options.maxConsole,
    });
    removeRecorder = attachRecorder(cdp, targetSessionId, recorder);

    const loadEvent = createTargetEventWaiter(
      cdp,
      targetSessionId,
      "Page.loadEventFired",
      options.navigationTimeoutMs,
    );
    let navigation;
    let navigationError = null;
    let loadEventTimedOut = false;
    try {
      navigation = await cdp.send(
        "Page.navigate",
        { url: options.targetUrl.toString() },
        targetSessionId,
        options.navigationTimeoutMs,
      );
    } catch (error) {
      loadEvent.cancel();
      throw error;
    }
    if (navigation?.errorText) {
      loadEvent.cancel();
      navigationError = sanitizeNetworkError(navigation.errorText);
    } else {
      try {
        await loadEvent.promise;
      } catch (error) {
        if (
          error instanceof CaptureError &&
          error.code === "CDP_EVENT_TIMEOUT"
        ) {
          loadEventTimedOut = true;
        } else {
          throw error;
        }
      }
    }
    await sleep(options.settleMs);

    const domMetrics = sanitizeDomMetrics(
      await evaluateValue(cdp, targetSessionId, DOM_METRICS_EXPRESSION),
      hmacKey,
    );
    const privacyRedaction = await evaluateValue(
      cdp,
      targetSessionId,
      SCREENSHOT_IP_MASK_EXPRESSION,
    );
    if (
      privacyRedaction?.applied !== true ||
      privacyRedaction?.remainingIpLiteralCount !== 0
    ) {
      throw new CaptureError(
        "SCREENSHOT_PRIVACY",
        "Screenshot was blocked because visible IP masking could not be verified.",
      );
    }
    const visibleIpEvidenceByHash = new Map();
    for (const rawLiteral of Array.isArray(
      privacyRedaction.maskedIpLiterals,
    )
      ? privacyRedaction.maskedIpLiterals
      : []) {
      const hashed = hashVisibleIpLiteral(rawLiteral, hmacKey);
      if (hashed) visibleIpEvidenceByHash.set(hashed.ipHash, hashed);
    }
    if (Array.isArray(privacyRedaction.maskedIpLiterals)) {
      privacyRedaction.maskedIpLiterals.fill(null);
      delete privacyRedaction.maskedIpLiterals;
    }
    const visibleIpEvidence = Array.from(visibleIpEvidenceByHash.values());
    if (options.kind === "diagnostic") {
      const diagnosticBlur = await evaluateValue(
        cdp,
        targetSessionId,
        DIAGNOSTIC_BLUR_EXPRESSION,
      );
      if (diagnosticBlur?.applied !== true) {
        throw new CaptureError(
          "SCREENSHOT_PRIVACY",
          "Diagnostic screenshot blur could not be verified.",
        );
      }
    }
    await sleep(100);

    const screenshot = await cdp.send(
      "Page.captureScreenshot",
      {
        format: "png",
        fromSurface: true,
        captureBeyondViewport: false,
      },
      targetSessionId,
    );
    if (
      typeof screenshot?.data !== "string" ||
      !/^[A-Za-z0-9+/=]+$/.test(screenshot.data)
    ) {
      throw new CaptureError(
        "SCREENSHOT_CAPTURE",
        "CDP did not return a valid screenshot.",
      );
    }
    const screenshotBytes = Buffer.from(screenshot.data, "base64");
    const screenshotName = "viewport-redacted.png";
    await writeExclusive(
      path.join(captureDirectory, screenshotName),
      screenshotBytes,
    );
    screenshotWritten = true;

    const requestedDestination = destinationIdentity(
      options.targetUrl.hostname,
      hmacKey,
    );
    const evidence = {
      schemaVersion: EVIDENCE_SCHEMA_VERSION,
      verdict: "NOT_ASSIGNED",
      capturePurpose: "PHYSICAL_BROWSER_EVIDENCE_ONLY",
      capturedAt: new Date().toISOString(),
      captureId,
      hashScope: {
        id: hashScopeId,
        algorithm: "HMAC-SHA-256",
        keyPersistence: options.hmacKeyFile
          ? "SESSION_KEY_FILE_NOT_EMBEDDED"
          : "EPHEMERAL_NOT_WRITTEN",
        comparability: options.hmacKeyFile
          ? "CROSS_CAPTURE_WITH_SAME_SESSION_KEY"
          : "SINGLE_CAPTURE_ONLY",
      },
      site: {
        id: options.siteId,
        kind: options.kind,
        requestedHostname: requestedDestination.hostname,
        requestedHostnameIpHash: requestedDestination.hostnameIpHash,
        requestedHostnameIpFamily: requestedDestination.hostnameIpFamily,
        requestedHostnameIpScope: requestedDestination.hostnameIpScope,
      },
      operatorClaim: {
        preset: options.preset,
        session: options.session,
        presetControl:
          "OPERATOR_SUPPLIED; HARNESS_DOES_NOT_MUTATE_OR_VERIFY_ZEON_PRESET",
      },
      device: {
        serialHash: hmacSensitive(options.serial, hmacKey, "adb-serial"),
        model: "GM1901",
        api: 36,
      },
      browser: {
        package: EDGE_PACKAGE,
        product: safeBrowserProduct(version.Browser),
        protocolVersion: safeProtocolVersion(version["Protocol-Version"]),
        isolation:
          "Target.createBrowserContext(disposeOnDetach)+Target.createTarget",
      },
      privacy: {
        persistedUrlParts: "HOSTNAME_ONLY",
        rawRemoteIpPersisted: false,
        rawConsoleTextPersisted: false,
        screenshotIpMasking: "DOM_LITERAL_MASK",
        diagnosticBroadBlur: options.kind === "diagnostic",
        maskedIpLiteralCount:
          Number.isInteger(privacyRedaction.maskedIpLiteralCount) &&
          privacyRedaction.maskedIpLiteralCount >= 0
            ? privacyRedaction.maskedIpLiteralCount
            : null,
        maskedIpLiteralsTruncated:
          privacyRedaction.maskedIpLiteralsTruncated === true,
        visibleIpEvidence,
        inaccessibleFrameCount:
          Number.isInteger(privacyRedaction.inaccessibleFrameCount) &&
          privacyRedaction.inaccessibleFrameCount >= 0
            ? privacyRedaction.inaccessibleFrameCount
            : null,
      },
      page: domMetrics,
      navigation: {
        error: navigationError,
        loadEventTimedOut,
        classification: "BROWSER_OUTCOME_NOT_VERDICT",
      },
      network: {
        resources: recorder.resources,
        activeAtCaptureCount: recorder.activeRequests.size,
        droppedResourceCount: recorder.droppedResources,
      },
      console: {
        events: recorder.console,
        droppedEventCount: recorder.droppedConsole,
      },
      screenshot: {
        file: screenshotName,
        sha256: createHash("sha256").update(screenshotBytes).digest("hex"),
        redacted: true,
        viewportOnly: true,
      },
    };
    assertSanitizedEvidence(evidence);
    await writeJsonAtomic(path.join(captureDirectory, "evidence.json"), evidence);
    return captureDirectory;
  } catch (error) {
    if (screenshotWritten) {
      await rm(path.join(captureDirectory, "viewport-redacted.png"), {
        force: true,
      }).catch(() => {});
    }
    await rm(captureDirectory, { recursive: true, force: true }).catch(() => {});
    throw error;
  } finally {
    let targetClosed = targetId === null;
    let contextDisposed = browserContextId === null;
    let webSocketClosed = cdp === null;
    removeRecorder?.();
    if (cdp && targetId) {
      try {
        const result = await cdp.send(
          "Target.closeTarget",
          { targetId },
          undefined,
          5000,
        );
        targetClosed = result?.success !== false;
      } catch {
        // disposeBrowserContext below is the second bounded cleanup path.
      }
    }
    if (cdp && browserContextId) {
      try {
        await cdp.send(
          "Target.disposeBrowserContext",
          { browserContextId },
          undefined,
          5000,
        );
        contextDisposed = true;
      } catch {
        // disposeOnDetach guarantees cleanup when the WebSocket closes.
      }
    }
    if (cdp) {
      try {
        webSocketClosed = await cdp.close();
      } catch {
        // Continue to mandatory ADB forward cleanup.
      }
    }
    let forwardRemoved = true;
    if (localPort) {
      forwardRemoved = removeForward(options, localPort);
    }
    hmacKey.fill(0);
    const isolatedStateReleased =
      browserContextId === null ||
      contextDisposed ||
      webSocketClosed;
    const exactTargetReleased =
      targetId === null ||
      targetClosed ||
      contextDisposed ||
      webSocketClosed;
    if (!isolatedStateReleased || !exactTargetReleased || !forwardRemoved) {
      await rm(captureDirectory, { recursive: true, force: true }).catch(
        () => {},
      );
      throw new CaptureError(
        "CLEANUP_FAILED",
        "Exact target/context/ADB-forward cleanup could not be confirmed.",
      );
    }
  }
}

function printHelp() {
  process.stdout.write(`Usage:
  node scripts/stage2_8_physical_cdp_capture.mjs \\
    --site-id yandex \\
    --url https://yandex.ru/ \\
    --kind service \\
    --preset Russia \\
    --session direct-dns-001 \\
    --serial 18bfc103

Required:
  --site-id ID                 Safe artifact identifier
  --url HTTPS_URL              Exact in-memory navigation URL; only hostname persists
  --kind service|diagnostic    Enables broad screenshot blur for diagnostics
  --preset Direct|Russia|Global
  --session ID
  --serial SERIAL

Optional:
  --adb PATH
  --output-root PATH
  --settle-ms 15000
  --navigation-timeout-ms 45000
  --max-resources 5000
  --max-console 1000
  --hmac-key-file PATH         Reuse one private 32-byte key for matrix comparison

The operator must select the ZEON preset before capture. This harness never
changes ZEON state and never assigns a browser verdict. If Edge is sleeping,
the harness only resumes its explicit MAIN/LAUNCHER activity before creating
the isolated CDP context. It never reads or captures that current page.
Unsupported browser contexts fail closed as INCONCLUSIVE.
For Direct/Russia/Global comparison, pass the same --hmac-key-file stored under
the ignored local evidence directory. The key is created with restricted
permissions where supported and is never embedded in evidence or logs.
`);
}

async function main() {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) {
      printHelp();
      return;
    }
    const directory = await capture(options);
    process.stdout.write(
      `Capture complete (verdict NOT_ASSIGNED): ${directory}\n`,
    );
  } catch (error) {
    const code =
      error instanceof CaptureError ? error.code : "CAPTURE_INTERNAL";
    const message =
      error instanceof CaptureError
        ? error.message
        : "Capture failed without persisting unsanitized diagnostics.";
    process.stderr.write(`Capture failed [${code}]: ${message}\n`);
    process.exitCode = 1;
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  await main();
}
