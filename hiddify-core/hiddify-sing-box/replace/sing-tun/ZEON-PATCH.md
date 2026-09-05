# Pinned sing-tun lifecycle correction

Source: github.com/sagernet/sing-tun v0.8.11, copied without changes before
applying the patch. The upstream LICENSE and embedded Wintun binaries remain.
Go module checksum: h1:BFu4+8LNl2JiTQtto5f+5AbkH90qgdoZEAqUbGiEXCg=

The only production change is in `LinkEndpointFilter.Attach`: preserve a nil
dispatcher when detaching. The upstream wrapper turns nil into a non-nil
`networkDispatcherFilter`, preventing fdbased endpoint Stop/Wait from running.
Native packet polling can then retain the kernel tunnel after its descriptors
are closed. On OnePlus Android 16, VPN to Local Proxy left tun0 and the old VPN
network active, while packets from other applications timed out.

The two regression tests exercise dispatcher identity and actual fdbased reader
shutdown through a socket pair, without requiring a privileged TUN or routes.
They both fail on the untouched upstream version. Run with `go test -tags
with_gvisor -run TestFilter .` (Linux executes the native polling test).

Both parent modules replace this dependency locally so builds and tests use the
same source. Re-audit and remove this patch when updating to an upstream version
that preserves nil detach semantics. Device regression acceptance is tracked in
the recovery investigation and TickTick; this source note does not assert a release.
