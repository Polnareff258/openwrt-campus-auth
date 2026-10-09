# OpenWrt Campus Auth

A small OpenWrt shell client for automatic campus-network authentication. The bundled portal adapter targets the verified Xiangtan University (XTU) portal at `zz.xtu.edu.cn` (Ruijie portal with CAS sign-in). Portal flows are site-specific; this project does not claim to support every campus network.

## Requirements

- OpenWrt with `/bin/ash`, UCI, ubus and the `jshn` library
- `curl`, `ca-bundle`, `openssl-util`, `jsonfilter`, `flock`
- A WAN interface named `wan`

The install script checks for the commands and `jshn` library, but package installation depends on your router's package manager and firmware feeds.

## Install

Copy this project directory to the router, then run as root:

```sh
cd openwrt-campus-auth
/bin/ash ./install.sh
/usr/bin/campus-auth-setup
```

The first command installs the auth client, its XTU adapter, WAN source-routing helper, hotplug hook, init script and credential setup command. It does not create a credentials file, start the auth daemon, or alter network or mwan3 configuration.

The interactive setup command prompts for the campus username and password without echoing the password. It creates `/etc/config/campus-auth` with mode `0600`, adds a five-minute bootstrap retry job to root's crontab, and restarts cron. It refuses to overwrite an existing credentials file. Authentication attempts are deferred until 06:00 according to the router clock. Failed attempts back off for 5, 10, 20, then 30 minutes (and every 30 minutes after that). The first successful authentication installs the runtime triggers and enables and starts the service automatically. If the router is already authenticated during setup, the client makes no login request, so bootstrap stays pending; wait until authentication is needed and run `campus-auth auto`, or explicitly enable the service through UCI if you want it active immediately.

Useful commands:

```sh
/usr/bin/campus-auth status
/usr/bin/campus-auth auto
```

The client stores transient login state under `/tmp/campus-auth` with restrictive permissions and avoids printing credentials or portal tokens in normal status output. Treat router backups and diagnostic bundles as sensitive.

## WAN routing

`stage2/wan-health.sh` is part of the core client. It pins campus probes and portal traffic to the source address on `wan` using an owned policy-routing table (table 201, rule preference 800). It expects an active WAN with an IPv4 address and gateway. Review those identifiers before installing on a router that already uses the same table or rule preference.

## Optional dual-WAN helper

`dualwan/reconcile-campus-primary.sh` is an optional helper for a separately configured mwan3 dual-WAN setup. It checks the `wan` tracking state and tests outbound HTTP/HTTPS before asking OpenWrt's existing hotplug event path to reconcile policy state. It is not installed by `install.sh`. Read and adapt it for your router before scheduling it; its cron job and mwan3 policy configuration are intentionally left to the operator.

## Files

- `stage2/campus-auth.sh` — probe, classify and coordinate login attempts
- `stage2/campus-auth-modern.sh` — XTU CAS/Ruijie portal adapter
- `stage2/wan-health.sh` — source-specific WAN routing for probes and portal requests
- `stage2/95-campus-auth` — WAN hotplug login trigger
- `campus-auth.init` — procd service definition
- `setup.sh` — interactive credential setup, installed as `/usr/bin/campus-auth-setup`
- `dualwan/reconcile-campus-primary.sh` — optional mwan3 reconciliation helper

## License

MIT. See [LICENSE](LICENSE).