# Windows security audit — 2026-07-18

## Scope and threat model

Reviewed the Windows Flutter runner, local credential/profile storage, persistent logs, release packaging, installer update flow, process privileges, and native PE hardening for ZEON `1.3.0+103002`.

The practical goals are:

- prevent casual extraction of JWTs, connection links, profile URLs, and generated configs from copied application data;
- avoid leaking credentials through release logs or an attached console;
- make distributed binaries tamper-evident and reduce DLL/preload and memory-corruption attack surface;
- preserve profiles and settings during an in-place update.

No desktop client can keep a secret from malware already executing as the same Windows user, an administrator, or code injected into the ZEON process. Server-side token expiry, revocation, scope restrictions, and abuse controls remain mandatory.

## Findings and changes

### 1. Secure-storage concurrency could hide an existing profile (high)

The installed Windows implementation of `flutter_secure_storage` 9.x stores all values in one DPAPI-protected `flutter_secure_storage.dat` file. Concurrent reads and writes can race. The observed failure was:

- the encrypted profile and its `active` database flag remained intact;
- DPAPI storage temporarily failed to read because the file was in use;
- profile metadata could not be decrypted;
- `activeProfileProvider` entered an error state and the UI displayed its `anonymous` fallback.

The affected local installation was checked without printing any profile values: one profile still exists, it is active, its metadata is protected, the profile encryption key is present, and the DPAPI file remains decryptable by the current Windows user.

Remediation:

- all app secure-storage operations now share one serialized queue;
- a profile-key read is retried four times on transient failures;
- a malformed/unavailable production key is never silently replaced with a new key;
- a successfully loaded key is cached for the process lifetime.

This preserves compatibility with the current Android dependency stack while backporting the relevant Windows concurrency protection.

### 2. Profile metadata was plaintext in SQLite on Windows (high)

Generated profile configs were already AES-256-GCM encrypted, with their key stored through platform secure storage. However, Windows SQLite still contained profile names, subscription URLs, support/web URLs, populated headers, and profile/user overrides in plaintext.

`ProtectedProfileDataSource` is now enabled on Windows. Existing rows are migrated in place and new/edited rows are encrypted before being stored. Profile IDs, active state, traffic counters, and scheduling fields remain queryable because the app needs them for normal operation.

### 3. Release logs could persist credentials (high)

Windows release builds always keep `app.log`. The file printer previously wrote messages, errors, and stack traces verbatim, and its `minLevel` setting was not enforced.

Remediation:

- a shared redactor masks JWTs, bearer/basic credentials, mobile API keys, credential-like key/value pairs, proxy links, web URLs, and IP addresses;
- redaction applies to log messages, attached errors, and stack traces;
- log minimum level is enforced;
- release builds do not emit application logs to an attached desktop console.

The same redactor is used for diagnostic reports so the policies cannot drift independently.

### 4. Distributed Windows executables were unsigned (critical release issue)

The inspected current and historical ZEON executables/installers had no Authenticode signature. Without a trusted code-signing certificate, users cannot reliably verify the publisher or detect a replaced installer, and Windows reputation/SmartScreen behavior is worse.

The packaging script now fails closed for distributable EXE builds unless either a PFX path or certificate-store thumbprint is provided. It signs previously unsigned EXE/DLL payload files, signs the final installer, timestamps the signatures, and verifies them with `signtool`.

`-AllowUnsignedExe` remains available only for explicit local testing and prints a warning. It must not be used for a public release.

MSIX packaging no longer creates a self-signed certificate by default or uses the predictable `zeon-local` password. Development certificate creation requires the explicit `-AllowDevelopmentMsixCertificate` flag. The temporary YAML password is cleared in `finally` after packaging.

### 5. Native runner hardening (medium)

The Windows runner now:

- requests `asInvoker` with `uiAccess=false`, preventing implicit elevation;
- removes the current working directory from DLL search and limits default DLL locations to the application directory, System32, and explicitly added user directories;
- enables high-entropy ASLR, dynamic base, NX/DEP, Control Flow Guard, SDL checks, and CET compatibility for release/profile builds.

TUN mode may still require the user to launch the application elevated. A future architecture should move privileged networking into a small, authenticated service instead of elevating the full UI process.

## Update behavior

An in-place update keeps the standard application data under the existing Windows application-support directory. The profile database, encrypted configs, preferences, and DPAPI storage are not part of the application folder and are not removed by replacing program files.

The observed `anonymous` state was not data deletion. After rebuilding with the secure-storage serialization fix and restarting the application, the existing active profile should be revealed normally.

Portable mode is intentionally weaker because its database and runtime config live beside the executable. Do not distribute portable builds as the primary credential-bearing production build.

## Release signing

Preferred certificate-store/HSM flow:

```powershell
$env:ZEON_WINDOWS_SIGNING_THUMBPRINT = '<SHA-1 certificate thumbprint>'
.\scripts\package_windows_installers.ps1 -Target exe
```

PFX flow:

```powershell
$env:ZEON_WINDOWS_SIGNING_PFX = 'D:\secure\zeon-code-signing.pfx'
$env:ZEON_WINDOWS_SIGNING_PASSWORD = '<secret>'
.\scripts\package_windows_installers.ps1 -Target exe
```

Use a publicly trusted organization or EV code-signing certificate for public EXE distribution. Keep the private key outside the repository; a hardware-backed/certificate-store key is preferable to an exportable PFX.

For production MSIX, place the intended certificate at the configured `certificate_path`, ensure its subject matches the MSIX publisher, provide `ZEON_MSIX_CERTIFICATE_PASSWORD`, and package with `-UseExistingCertificateOnly`.

## Verification performed

- targeted Dart analysis: no issues;
- secure-storage serialization, failure recovery, log redaction, mobile sensitive-storage migration, and diagnostic-redaction tests: 10 passed;
- PowerShell packaging script parser: no syntax errors;
- isolated Windows release build: successful without stopping or replacing the running ZEON process;
- built version: `1.3.0+103002`;
- PE flags confirmed: high-entropy VA, dynamic base, NX compatible, Control Flow Guard, and CET compatible;
- embedded manifest confirmed: `asInvoker`, `uiAccess=false`, and Per-Monitor V2 DPI awareness.

The isolated raw EXE was intentionally unsigned and used only to verify compilation. A public artifact must be created by the signing-enforcing packaging workflow.

## Residual risks and priorities

1. Rotate any mobile API key that has already been committed or shipped. A static client key can always be extracted from Android or Windows binaries; replace it with server-issued, short-lived, scoped credentials and abuse controls.
2. Runtime core configuration must temporarily exist in plaintext while the VPN core consumes it. Standard installed mode inherits per-user application-data ACLs, but same-user malware/admin can read it. Delete stale runtime configs whenever the core lifecycle permits.
3. Review WARP/license-related preferences that remain in SharedPreferences and move true bearer credentials into serialized secure storage.
4. Purchase/configure a trusted Windows code-signing certificate before distributing `1.3.0`; current historical installers are unsigned.
5. Consider a privileged Windows service for TUN mode so the UI, updater links, parsers, and network-facing code do not run elevated.
