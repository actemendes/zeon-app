#ifndef RUNNER_STARTUP_DIAGNOSTICS_H_
#define RUNNER_STARTUP_DIAGNOSTICS_H_

// Writes a single best-effort marker when ZEON_STARTUP_DIAGNOSTICS_FILE is
// configured. Production launches without that environment variable are a
// no-op.
void WriteStartupMarker(const char* marker);

#endif  // RUNNER_STARTUP_DIAGNOSTICS_H_
