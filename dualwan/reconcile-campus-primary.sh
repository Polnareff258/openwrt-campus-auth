#!/bin/ash
# Recover a missed mwan3 connected event after verifying the campus exit.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
hour=$(date +%H)
case "$hour" in 00|01|02|03|04|05) exit 0 ;; esac
[ -x /usr/sbin/mwan3 ] || exit 0
[ "$(cat /var/run/mwan3track/wan/STATUS 2>/dev/null)" = online ] || exit 0
if [ "${1:-}" != verify ]; then
    [ "$(cat /var/run/mwan3/iface_state/wan 2>/dev/null)" != online ] || exit 0
fi
exec 8>/var/lock/campus-primary-reconcile.lock
flock -n 8 || exit 0
/usr/lib/campus-auth/wan-health.sh sync-campus >/dev/null 2>&1 || exit 0
j=$(ubus call network.interface.wan status 2>/dev/null) || exit 0
[ "$(printf '%s' "$j" | jsonfilter -e '@.up')" = true ] || exit 0
source_ip=$(printf '%s' "$j" | jsonfilter -e '@["ipv4-address"][0].address')
device=$(printf '%s' "$j" | jsonfilter -e '@.l3_device')
[ -n "$source_ip" ] && [ -n "$device" ] || exit 0
http_code=$(curl -4 --interface "$source_ip" -s --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204) || http_code=000
https_code=$(curl -4 --interface "$source_ip" -s --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' https://www.baidu.com/) || https_code=000
[ "$http_code" = 204 ] && [ "$https_code" = 200 ] || exit 0
env -i PATH="$PATH" ACTION=connected INTERFACE=wan DEVICE="$device" /sbin/hotplug-call iface || exit 1
logger -t campus-auth CAMPUS_PRIMARY_POLICY_RECONCILED
echo CAMPUS_PRIMARY_VERIFIED
