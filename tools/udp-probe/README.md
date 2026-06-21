# Zeon UDP Probe

UDP-only endpoint for lightweight VPN route quality checks. It is not HTTP,
does not listen on TCP, and does not use nginx.

## Packet

All integers are big-endian. Packets are authenticated with HMAC-SHA256.

```text
magic[8]       ZEONUDP1
version[1]     1
type[1]        1=request, 2=response
header_len[2]  48
timestamp_ns[8]
session_id[16]
seq[4]
packet_count[4]
payload_len[2]
reserved[2]
payload[n]
hmac[32]       HMAC-SHA256(header + payload)
```

Server accepts packets from 96 to 1200 bytes. Timestamps must be within 30
seconds. Invalid packets receive no response. Responses are never larger than
the request packet.

## Build

```bash
go build -o zeon-udp-probe ./cmd/zeon-udp-probe
```

## Run Server

```bash
export ZEON_UDP_PROBE_SECRET="$(openssl rand -hex 32)"
./zeon-udp-probe server -listen :8443
```

## systemd

```bash
useradd --system --no-create-home --shell /usr/sbin/nologin zeon-udp-probe || true
mkdir -p /etc/zeon
install -o root -g root -m 0755 zeon-udp-probe /usr/local/bin/zeon-udp-probe
install -o root -g root -m 0644 deploy/zeon-udp-probe.service /etc/systemd/system/zeon-udp-probe.service
printf 'ZEON_UDP_PROBE_SECRET=%s\nZEON_UDP_PROBE_LISTEN=:8443\n' "$(openssl rand -hex 32)" > /etc/zeon/udp-probe.env
chmod 600 /etc/zeon/udp-probe.env
systemctl daemon-reload
systemctl enable --now zeon-udp-probe.service
```

## Test Client

```bash
ZEON_UDP_PROBE_SECRET="same-secret" ./zeon-udp-probe client -addr udp-probe.zeon-vps.link:8443 -count 20 -size 160
```

The client reports sent, received, loss, RTT min/avg/max, and jitter.

## Firewall

UFW:

```bash
ufw allow 8443/udp comment "Zeon UDP probe"
ufw status verbose
```

iptables:

```bash
iptables -A INPUT -p udp --dport 8443 -j ACCEPT
```

Do not add a TCP 8443 rule for this service.

## DNS

Create a plain DNS A record:

```text
udp-probe.zeon-vps.link A 92.46.41.206
```

Do not put this record behind a normal HTTP/Web Cloudflare proxy. This service
uses custom UDP packets, not HTTP or HTTPS.

## Checks

```bash
systemctl status zeon-udp-probe.service --no-pager
ss -lunp | grep ':8443'
ss -ltnp | grep ':8443' || true
journalctl -u zeon-udp-probe.service -f
```
