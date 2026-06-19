# Subscription Update Routing Through VPN

## Problem

On Android, the VPN service excludes Zeon from the TUN interface to prevent the core's own sockets from looping into the VPN. Therefore, a Dart/Dio request made by the application is not captured by TUN automatically.

The subscription downloader uses sing-box's local mixed proxy. Previously it selected the `both` HTTP mode, which configured `PROXY 127.0.0.1:<mixedPort>; DIRECT`. If the local proxy was unavailable, the request could fall back to the mobile network directly. On restricted mobile networks this resulted in a connection timeout even while other VPN traffic worked.

## Behaviour after the fix

When the core reports `Connected`, manual and scheduled subscription updates pass `proxyOnly: true` to the profile downloader. The downloader then uses only the local mixed proxy and never has a direct fallback.

When disconnected, subscription updates retain the direct-or-proxy fallback behavior, so profiles can still be imported or refreshed before connecting.

Nested remote links in a subscription use the same routing mode. HTTP-client logs record whether the required proxy mode or the fallback-capable mode was selected.
