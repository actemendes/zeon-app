# Smart Active Auto: active-server monitoring

Smart Active Auto runs a separate lightweight probe through the exact outbound
returned by `SmartActive.Now()`. The probe does not replace or partially update
the full-generation history used to rank the server pool.

## Schedule

Each newly active server is checked immediately, then at 10, 20, 30, 40, 50,
and 60 seconds after it became active. Checks continue once per minute after
that. Any active-server change resets the schedule and starts again at zero.

## Probe size and switching safety

A normal check sends one HTTP `HEAD` request and, when the authenticated UDP
probe is configured, up to three 128-byte UDP packets. It does not request IP
metadata and never probes the rest of the pool.

A failed HTTP check, latency of at least 1500 ms, or at least 80% UDP loss first
starts one small confirmation probe. Smart Active switches only when the same
class of problem is confirmed. A successful confirmation clears the evidence.
Lower packet loss and an isolated delay spike do not switch the active server.

If there is no previously verified failover candidate, Smart Active requests a
full recovery generation. A successful fresh result from the current active
server cancels the pending failover; otherwise the best fresh healthy candidate
is selected.

## Release UDP configuration

The authenticated UDP endpoint can be enabled in release builds without
putting its key in logs:

```text
--dart-define=udp_probe_enabled=true
--dart-define=udp_probe_secret=<deployment-key>
--dart-define=udp_probe_endpoint=udp-probe.zeon-vps.link:8443
```

The endpoint define is optional. Without an enabled authenticated endpoint,
the HTTP health check still runs and UDP remains unknown rather than being
treated as a failure.
