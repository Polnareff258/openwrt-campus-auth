#!/bin/ash
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for cmd in cp chmod mkdir curl openssl jsonfilter flock uci ubus; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
[ -r /usr/share/libubox/jshn.sh ] || { echo "Missing OpenWrt jshn library (/usr/share/libubox/jshn.sh)." >&2; exit 1; }

mkdir -p /usr/lib/campus-auth /etc/hotplug.d/iface /etc/init.d /usr/bin
cp "$BASE/stage2/campus-auth.sh" /usr/bin/campus-auth
cp "$BASE/stage2/campus-auth-modern.sh" /usr/lib/campus-auth/campus-auth-modern.sh
cp "$BASE/stage2/wan-health.sh" /usr/lib/campus-auth/wan-health.sh
cp "$BASE/stage2/95-campus-auth" /usr/lib/campus-auth/95-campus-auth
cp "$BASE/campus-auth.init" /etc/init.d/campus-auth
cp "$BASE/setup.sh" /usr/bin/campus-auth-setup
chmod 755 /usr/bin/campus-auth /usr/lib/campus-auth/campus-auth-modern.sh /usr/lib/campus-auth/wan-health.sh /usr/lib/campus-auth/95-campus-auth /etc/init.d/campus-auth /usr/bin/campus-auth-setup

# The initial setup installs the WAN event hook; the helper copies it only after
# the first successful portal login and then enables the service.
cp "$BASE/stage2/95-campus-auth" /etc/hotplug.d/iface/95-campus-auth
chmod 755 /etc/hotplug.d/iface/95-campus-auth

echo "Installed campus-auth files. No campus config was created and no service or network settings were changed."
echo "Run /usr/bin/campus-auth-setup in an interactive root terminal to enter your credentials."
echo "Setup creates /etc/config/campus-auth and adds its retry job to root's crontab."