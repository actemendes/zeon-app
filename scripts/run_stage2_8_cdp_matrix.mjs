#!/usr/bin/env node

import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "..");

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      throw new Error(`Unexpected argument: ${token}`);
    }
    const key = token.slice(2);
    if (key === "list") {
      result.list = true;
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`Missing value for --${key}`);
    }
    result[key] = value;
    index += 1;
  }
  return result;
}

function loadCatalog() {
  const source = readFileSync(join(scriptDir, "validate_stage2_8_ru_browser.ps1"), "utf8");
  const header = "Id,Name,Url,Kind,Applicable";
  const start = source.indexOf(header);
  const end = source.indexOf("\n'@", start);
  if (start < 0 || end < 0) {
    throw new Error("Stage 2.8 browser catalog was not found");
  }
  const rows = source
    .slice(start, end)
    .trim()
    .split(/\r?\n/u);
  const sites = rows.slice(1).map((line) => {
    const columns = line.split(",");
    if (columns.length !== 5) {
      throw new Error(`Unsupported catalog row: ${line}`);
    }
    return {
      id: columns[0],
      name: columns[1],
      url: columns[2],
      kind: columns[3] === "diagnostic" ? "diagnostic" : "service",
      applicable: columns[4],
    };
  });
  const mandatoryCount = sites.filter((site) => site.kind === "service").length;
  const diagnosticCount = sites.filter((site) => site.kind === "diagnostic").length;
  if (mandatoryCount !== 36 || diagnosticCount !== 8 || sites.length !== 44) {
    throw new Error(
      `Catalog arithmetic mismatch: mandatory=${mandatoryCount} diagnostic=${diagnosticCount} total=${sites.length}`,
    );
  }
  return sites;
}

function run(file, args, timeoutMs = 120_000) {
  return spawnSync(file, args, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: timeoutMs,
    windowsHide: true,
    maxBuffer: 16 * 1024 * 1024,
  });
}

function runAdb(adb, serial, args, timeoutMs = 30_000) {
  return run(adb, ["-s", serial, ...args], timeoutMs);
}

function csv(value) {
  const text = String(value ?? "");
  return `"${text.replaceAll('"', '""')}"`;
}

function parseCapturePath(stdout) {
  const match = String(stdout).match(/Capture complete \(verdict NOT_ASSIGNED\):\s*(.+)\s*$/mu);
  return match?.[1]?.trim() ?? "";
}

function totalRssKiB(adb, serial) {
  const result = runAdb(adb, serial, ["shell", "dumpsys", "meminfo", "com.zeon.hiddify"]);
  const match = String(result.stdout).match(/TOTAL RSS:\s*(\d+)/u);
  return match ? Number.parseInt(match[1], 10) : 0;
}

function zeonProcessPresent(adb, serial) {
  const result = runAdb(adb, serial, ["shell", "ps", "-A"]);
  return String(result.stdout).includes("com.zeon.hiddify");
}

function captureOnce(options, site) {
  return run(
    process.execPath,
    [
      join(scriptDir, "stage2_8_physical_cdp_capture.mjs"),
      "--site-id",
      site.id,
      "--url",
      site.url,
      "--kind",
      site.kind,
      "--preset",
      options.preset,
      "--session",
      options.session,
      "--serial",
      options.serial,
      "--adb",
      options.adb,
      "--output-root",
      options.outputRoot,
      "--hmac-key-file",
      options.hmacKeyFile,
      "--context-mode",
      "allow-clean-tab",
      "--settle-ms",
      String(options.settleMs),
    ],
    120_000,
  );
}

function collectTelemetry(adb, serial) {
  const result = runAdb(
    adb,
    serial,
    ["logcat", "-d", "-v", "raw", "-s", "ZEON_ROUTE_VALIDATION:W", "*:S"],
    30_000,
  );
  if (result.status !== 0) {
    throw new Error(`logcat failed: ${result.stderr}`);
  }
  return String(result.stdout)
    .split(/\r?\n/u)
    .filter((line) => line.includes("ZEON_ROUTE_VALIDATION "))
    .join("\n");
}

const args = parseArgs(process.argv.slice(2));
let sites = loadCatalog();

if (args.list) {
  process.stdout.write(
    `${sites.map((site) => `${site.id}\t${site.kind}\t${site.url}`).join("\n")}\n`,
  );
  process.exit(0);
}

for (const required of ["preset", "session", "serial", "adb", "output-root", "hmac-key-file"]) {
  if (!args[required]) {
    throw new Error(`--${required} is required`);
  }
}
if (!["Direct", "Russia", "Global"].includes(args.preset)) {
  throw new Error("--preset must be Direct, Russia, or Global");
}
if (!existsSync(args.adb)) {
  throw new Error(`ADB was not found: ${args.adb}`);
}

if (args.sites) {
  const requested = new Set(args.sites.split(",").filter(Boolean));
  sites = sites.filter((site) => requested.has(site.id));
  if (sites.length !== requested.size) {
    throw new Error("At least one --sites ID is not present in the Stage 2.8 catalog");
  }
}

const options = {
  preset: args.preset,
  session: args.session,
  serial: args.serial,
  adb: resolve(args.adb),
  outputRoot: resolve(args["output-root"]),
  hmacKeyFile: resolve(args["hmac-key-file"]),
  settleMs: Number.parseInt(args["settle-ms"] ?? "8000", 10),
};
mkdirSync(options.outputRoot, { recursive: true });
mkdirSync(dirname(options.hmacKeyFile), { recursive: true });

const progressPath = join(options.outputRoot, `progress-${options.preset.toLowerCase()}.csv`);
if (!existsSync(progressPath)) {
  writeFileSync(
    progressPath,
    "capturedAtUtc,preset,siteId,status,capturePath,telemetryLines,zeonProcessPresent,totalRssKiB,durationMs,error\n",
    "utf8",
  );
}

runAdb(options.adb, options.serial, ["shell", "am", "force-stop", "com.microsoft.emmx"]);

for (const site of sites) {
  const started = Date.now();
  runAdb(options.adb, options.serial, ["logcat", "-c"]);
  let capture = captureOnce(options, site);
  let retried = false;
  if (capture.status !== 0) {
    retried = true;
    runAdb(options.adb, options.serial, ["shell", "am", "force-stop", "com.microsoft.emmx"]);
    runAdb(options.adb, options.serial, ["logcat", "-c"]);
    capture = captureOnce(options, site);
  }

  const capturePath = parseCapturePath(capture.stdout);
  let status = capture.status === 0 && capturePath ? "CAPTURED" : "CAPTURE_FAILED";
  let telemetryLines = 0;
  let error = String(capture.stderr || capture.stdout || "").trim();
  if (status === "CAPTURED" && options.preset !== "Direct") {
    try {
      const telemetry = collectTelemetry(options.adb, options.serial);
      telemetryLines = telemetry ? telemetry.split(/\r?\n/u).length : 0;
      writeFileSync(join(capturePath, "route-telemetry.log"), telemetry ? `${telemetry}\n` : "", "utf8");
    } catch (telemetryError) {
      status = "TELEMETRY_FAILED";
      error = String(telemetryError);
    }
  }
  const processPresent = zeonProcessPresent(options.adb, options.serial);
  const rssKiB = processPresent ? totalRssKiB(options.adb, options.serial) : 0;
  if (options.preset !== "Direct" && !processPresent) {
    status = "ZEON_PROCESS_LOST";
  }
  if (retried) {
    error = `retried; ${error}`;
  }

  appendFileSync(
    progressPath,
    [
      csv(new Date().toISOString()),
      csv(options.preset),
      csv(site.id),
      csv(status),
      csv(capturePath),
      csv(telemetryLines),
      csv(processPresent),
      csv(rssKiB),
      csv(Date.now() - started),
      csv(error),
    ].join(",") + "\n",
    "utf8",
  );
  process.stdout.write(
    `[${options.preset}] ${site.id}: ${status} telemetry=${telemetryLines} rssKiB=${rssKiB}\n`,
  );
}
