import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  DEVTOOLS_SOCKET,
  DIAGNOSTIC_BLUR_EXPRESSION,
  DOM_METRICS_EXPRESSION,
  EDGE_LAUNCHER_COMPONENT,
  EDGE_PACKAGE,
  EvidenceRecorder,
  SCREENSHOT_IP_MASK_EXPRESSION,
  VERSION_ENDPOINT,
  assertSanitizedEvidence,
  classifyIpFamily,
  classifyIpScope,
  destinationIdentity,
  hashRemoteAddress,
  hashVisibleIpLiteral,
  hostnameOnly,
  loadOrCreateHmacKey,
  localBrowserWebSocketUrl,
  parseAdbDevices,
  parseArgs,
  sanitizeConsoleCall,
  sanitizeNetworkError,
  sanitizeProtocol,
  sanitizeResponseTiming,
  stableHashScopeId,
} from "../stage2_8_physical_cdp_capture.mjs";

test("CLI requires the exact physical capture identity and keeps URL in memory only", () => {
  const options = parseArgs([
    "--site-id",
    "yandex",
    "--url",
    "https://yandex.ru/search/?text=stage2.8#fragment",
    "--kind",
    "service",
    "--preset",
    "Russia",
    "--session",
    "direct-dns-001",
    "--serial",
    "18bfc103",
  ]);

  assert.equal(options.siteId, "yandex");
  assert.equal(options.targetUrl.hostname, "yandex.ru");
  assert.equal(options.targetUrl.pathname, "/search/");
  assert.equal(options.kind, "service");
  assert.equal(options.preset, "Russia");
  assert.equal(options.serial, "18bfc103");
});

test("URL sanitization persists hostname only", () => {
  assert.equal(
    hostnameOnly("https://User:Secret@Example.COM/private?q=token#fragment"),
    "example.com",
  );
  assert.equal(hostnameOnly("not a url"), null);
});

test("remote IP is immediately reduced to family and capture-scoped HMAC", () => {
  const key = Buffer.alloc(32, 7);
  const ipv4 = "203.0.113.42";
  const ipv6 = "2001:db8::42";

  assert.equal(classifyIpFamily(ipv4), "IPv4");
  assert.equal(classifyIpFamily(`[${ipv6}]`), "IPv6");
  assert.equal(classifyIpFamily("not-an-ip"), "UNKNOWN");
  assert.equal(classifyIpScope("10.0.0.1"), "PRIVATE");
  assert.equal(classifyIpScope("100.64.0.1"), "SHARED_CGNAT");
  assert.equal(classifyIpScope("203.0.113.42"), "DOCUMENTATION");
  assert.equal(classifyIpScope("8.8.8.8"), "PUBLIC");
  assert.equal(classifyIpScope("fd00::1"), "PRIVATE");

  const hashed4 = hashRemoteAddress(ipv4, key);
  const hashed6 = hashRemoteAddress(ipv6, key);
  assert.equal(hashed4.ipFamily, "IPv4");
  assert.equal(hashed4.ipScope, "DOCUMENTATION");
  assert.equal(hashed6.ipFamily, "IPv6");
  assert.match(hashed4.remoteIpHash, /^hmac-sha256:[0-9a-f]{64}$/);
  assert.match(hashed6.remoteIpHash, /^hmac-sha256:[0-9a-f]{64}$/);
  assert.doesNotMatch(JSON.stringify([hashed4, hashed6]), /203\.0\.113\.42|2001:db8/);

  const literalHost = destinationIdentity(ipv4, key);
  assert.equal(literalHost.hostname, null);
  assert.equal(literalHost.hostnameIpFamily, "IPv4");
  assert.match(literalHost.hostnameIpHash, /^hmac-sha256:[0-9a-f]{64}$/);
  assert.doesNotMatch(JSON.stringify(literalHost), /203\.0\.113\.42/);

  const visible = hashVisibleIpLiteral(ipv6, key);
  assert.equal(visible.ipFamily, "IPv6");
  assert.equal(visible.ipScope, "DOCUMENTATION");
  assert.match(visible.ipHash, /^hmac-sha256:[0-9a-f]{64}$/);
  assert.doesNotMatch(JSON.stringify(visible), /2001:db8/);
});

test("optional private key file gives stable cross-capture hash scope", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "zeon-cdp-key-test-"));
  const keyPath = path.join(directory, "matrix-session.key");
  try {
    const first = await loadOrCreateHmacKey(keyPath);
    const second = await loadOrCreateHmacKey(keyPath);
    assert.equal(first.length, 32);
    assert.deepEqual(second, first);
    assert.equal(stableHashScopeId(first), stableHashScopeId(second));
    assert.match(stableHashScopeId(first), /^sha256:[0-9a-f]{64}$/);
    first.fill(0);
    second.fill(0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("network protocol, timing, and failures are allowlisted", () => {
  assert.equal(sanitizeProtocol("h3"), "h3");
  assert.equal(sanitizeProtocol("h2\r\nsecret"), "UNKNOWN");
  assert.equal(
    sanitizeNetworkError("net::ERR_CONNECTION_RESET at https://secret/path"),
    "net::ERR_CONNECTION_RESET",
  );
  assert.equal(sanitizeNetworkError("arbitrary private text"), "OTHER");
  assert.deepEqual(
    sanitizeResponseTiming({
      dnsStart: 1,
      dnsEnd: 3.5,
      connectStart: 3.5,
      connectEnd: 8,
      sslStart: 4,
      sslEnd: 7,
      sendStart: 8,
      sendEnd: 9,
      receiveHeadersEnd: 20,
    }),
    {
      dnsMs: 2.5,
      connectMs: 4.5,
      sslMs: 3,
      sendMs: 1,
      receiveHeadersMs: 11,
    },
  );
});

test("recorder never serializes request path, query, raw IP, or console text", () => {
  const key = randomBytes(32);
  const recorder = new EvidenceRecorder({
    hmacKey: key,
    maxResources: 10,
    maxConsole: 10,
  });
  recorder.onRequestWillBeSent({
    requestId: "request-1",
    timestamp: 100,
    type: "Document",
    request: {
      url: "https://service.example/private/account?token=TOP_SECRET",
      headers: { Cookie: "session=TOP_SECRET" },
      postData: "TOP_SECRET_BODY",
    },
  });
  recorder.onResponseReceived({
    requestId: "request-1",
    timestamp: 100.25,
    response: {
      status: 200,
      protocol: "h2",
      remoteIPAddress: "203.0.113.99",
      remotePort: 443,
      headers: { "Set-Cookie": "TOP_SECRET" },
      timing: {
        dnsStart: 0,
        dnsEnd: 1,
        connectStart: 1,
        connectEnd: 2,
        sslStart: 1.2,
        sslEnd: 1.8,
        sendStart: 2,
        sendEnd: 2.1,
        receiveHeadersEnd: 20,
      },
    },
  });
  recorder.onLoadingFinished({ requestId: "request-1", timestamp: 100.5 });
  recorder.onConsoleCall({
    timestamp: 5000,
    type: "error",
    args: [
      {
        type: "string",
        value:
          "TOP_SECRET console https://service.example/private 203.0.113.99",
      },
    ],
  });
  recorder.onRequestWillBeSent({
    requestId: "request-2",
    timestamp: 101,
    type: "Fetch",
    request: { url: "https://198.51.100.8/private" },
  });

  const evidence = {
    network: { resources: recorder.resources },
    console: { events: recorder.console },
  };
  assertSanitizedEvidence(evidence);
  const serialized = JSON.stringify(evidence);
  assert.equal(recorder.resources[0].hostname, "service.example");
  assert.equal(recorder.resources[0].ipFamily, "IPv4");
  assert.match(
    recorder.resources[0].remoteIpHash,
    /^hmac-sha256:[0-9a-f]{64}$/,
  );
  for (const forbidden of [
    "/private",
    "token=",
    "TOP_SECRET",
    "TOP_SECRET_BODY",
    "203.0.113.99",
    "198.51.100.8",
    "Cookie",
    "Set-Cookie",
  ]) {
    assert.equal(serialized.includes(forbidden), false, forbidden);
  }
});

test("console sanitizer stores only type, counts, and an HMAC", () => {
  const event = sanitizeConsoleCall(
    {
      type: "warning",
      args: [{ value: "private-token 198.51.100.4 /private/path" }],
    },
    Buffer.alloc(32, 3),
    12.5,
  );
  assert.deepEqual(Object.keys(event).sort(), [
    "argumentCount",
    "event",
    "level",
    "messageHash",
    "relativeMs",
  ]);
  assert.equal(event.level, "warning");
  assert.match(event.messageHash, /^hmac-sha256:[0-9a-f]{64}$/);
  assert.doesNotMatch(JSON.stringify(event), /private-token|198\.51\.100\.4|private\/path/);
});

test("evidence assertion rejects forbidden raw transport fields", () => {
  assert.throws(
    () =>
      assertSanitizedEvidence({
        resources: [{ hostname: "example.com", remoteIPAddress: "192.0.2.1" }],
      }),
    /Forbidden evidence field/,
  );
  assert.throws(
    () =>
      assertSanitizedEvidence({
        request: { headers: { Cookie: "secret" } },
      }),
    /Forbidden evidence field/,
  );
});

test("ADB parser exposes authorization state without needing browser data", () => {
  const devices = parseAdbDevices(`List of devices attached
18bfc103 device product:OnePlus7 model:GM1901 device:OnePlus7
`);
  assert.deepEqual(devices, [
    {
      serial: "18bfc103",
      state: "device",
      details: "product:OnePlus7 model:GM1901 device:OnePlus7",
    },
  ]);
});

test("browser discovery is pinned to version endpoint and local forwarded socket", () => {
  assert.equal(EDGE_PACKAGE, "com.microsoft.emmx");
  assert.equal(
    EDGE_LAUNCHER_COMPONENT,
    "com.microsoft.emmx/com.microsoft.ruby.Main",
  );
  assert.equal(DEVTOOLS_SOCKET, "localabstract:chrome_devtools_remote");
  assert.equal(VERSION_ENDPOINT, "/json/version");
  assert.equal(
    localBrowserWebSocketUrl(
      {
        webSocketDebuggerUrl:
          "ws://device-name:9222/devtools/browser/browser-id",
      },
      45678,
    ),
    "ws://127.0.0.1:45678/devtools/browser/browser-id",
  );
});

test("harness source contains no target enumeration or tab-list endpoint", async () => {
  const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
  const source = await readFile(
    path.resolve(currentDirectory, "../stage2_8_physical_cdp_capture.mjs"),
    "utf8",
  );
  const forbiddenMethod = ["Target", "getTargets"].join(".");
  const forbiddenEndpoint = ["/json", "list"].join("/");
  assert.equal(source.includes(forbiddenMethod), false);
  assert.equal(source.includes(forbiddenEndpoint), false);
  assert.equal(source.includes('"Target.createBrowserContext"'), true);
  assert.equal(source.includes("disposeOnDetach: true"), true);
  assert.equal(source.includes('"Target.createTarget"'), true);
  assert.equal(source.includes('"Target.attachToTarget"'), true);
  assert.equal(source.includes('"Target.closeTarget"'), true);
  assert.equal(source.includes('"Target.disposeBrowserContext"'), true);
  assert.equal(source.includes('verdict: "NOT_ASSIGNED"'), true);
  assert.equal(source.includes('verdict: "PASS"'), false);
  assert.equal(source.includes("navigationError = sanitizeNetworkError"), true);
  assert.equal(source.includes("loadEventTimedOut = true"), true);
  assert.equal(
    source.includes("com.microsoft.emmx/com.microsoft.ruby.Main"),
    true,
  );
  assert.equal(
    source.includes(
      "org.chromium.chrome.browser.incognito.OPEN_PRIVATE_TAB",
    ),
    false,
  );
  assert.equal(source.includes('"android.intent.action.MAIN"'), true);
  assert.equal(source.includes('"android.intent.category.LAUNCHER"'), true);
});

test("all injected page expressions parse before physical capture", () => {
  for (const expression of [
    DOM_METRICS_EXPRESSION,
    SCREENSHOT_IP_MASK_EXPRESSION,
    DIAGNOSTIC_BLUR_EXPRESSION,
  ]) {
    assert.doesNotThrow(() => new Function(`return (${expression});`));
  }
});
