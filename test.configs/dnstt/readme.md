# DNSTT Test Config

This folder contains DNSTT examples for ZEON App and local core testing.

## App Example

Use an app config like this, replacing `dnstt.example.com` and `xxxx` with your own DNSTT domain and public key:

```text
socks://#name -> dnstt://?tunnel_per_resolver=4&resolver=8.8.8.8:53&resolver=8.8.4.4:53&domain=dnstt.example.com&publicKey=xxxx
```

Or use a JSON outbound example:

```json
{
  "outbounds": [
    {
      "type": "socks",
      "tag": "socks",
      "version": "5",
      "detour": "dnstt1"
    },
    {
      "type": "dnstt",
      "tag": "dnstt1",
      "publicKey": "xxxx",
      "domain": "dnstt.example.com",
      "tunnel_per_resolver": 4,
      "resolvers": ["8.8.8.8:53", "8.8.4.4:53"]
    }
  ]
}
```

## CLI, Router, or Relay Server

Build or download the core binary required by the current ZEON development workflow, then run DNSTT with:

```powershell
<core-binary> srun -c config.json
```

See `dnstt_raw_config.json` for a raw configuration example.
