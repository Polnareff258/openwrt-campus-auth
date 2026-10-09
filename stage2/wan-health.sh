#!/bin/ash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
TABLE=201 PREF=800 STATE=/var/run/dualwan
mkdir -p "$STATE"; chmod 700 "$STATE"
LOCK=/var/lock/dualwan-route.lock

rule_ip() {
    ip -4 rule show | awk -v p="$PREF" -v t="$TABLE" '
      $1 ~ ("^" p ":$") { for(i=1;i<=NF;i++) if($i=="from") {x=$(i+1);sub(/\/32$/, "", x)} else if($i=="lookup"||$i=="table") {if($(i+1)==t) print x} }
    ' | head -n 1
}
campus_status() { ubus call network.interface.wan status 2>/dev/null; }
flush_owned_table() {
    if routes=$(ip -4 route show table "$TABLE" 2>/dev/null); then
        [ -z "$routes" ] || ip -4 route flush table "$TABLE" >/dev/null 2>&1 || return 1
    fi
    return 0
}
campus_sync_locked() {
    j=$(campus_status) || return 1
    up=$(printf '%s' "$j" | jsonfilter -e '@.up' 2>/dev/null)
    ip=$(printf '%s' "$j" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    dev=$(printf '%s' "$j" | jsonfilter -e '@.l3_device' 2>/dev/null)
    gw=$(printf '%s' "$j" | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    [ "$up" = true ] && [ -n "$ip" ] && [ -n "$dev" ] && [ -n "$gw" ] || return 1
    link_prefixes=$(ip -4 route show dev "$dev" scope link 2>/dev/null | awk '$1 ~ /^[0-9.]+\/[0-9]+$/ {print $1}')
    old=$(rule_ip)
    if [ -n "$old" ] && [ "$old" != "$ip" ]; then
        ip -4 rule del pref "$PREF" from "$old/32" table "$TABLE" 2>/dev/null || return 1
        flush_owned_table || return 1
        old=
    fi
    ip -4 rule show | awk -v p="$PREF" '$1 ~ ("^" p ":$") {found=1} END{exit !found}' && [ -z "$old" ] && return 1
    if [ -z "$old" ]; then ip -4 rule add pref "$PREF" from "$ip/32" table "$TABLE" || return 1; fi
    table_routes=$(ip -4 route show table "$TABLE" 2>/dev/null || true)
    links_ok=1
    for prefix in $link_prefixes; do
        printf '%s\n' "$table_routes" | grep -Fq "$prefix dev $dev" || links_ok=0
    done
    if [ "$(cat "$STATE/campus-route" 2>/dev/null)" = "$ip $dev $gw" ] &&
       printf '%s\n' "$table_routes" | grep -Fq "default via $gw dev $dev" &&
       [ "$links_ok" = 1 ]; then return 0; fi
    flush_owned_table || return 1
    for prefix in $link_prefixes; do
        ip -4 route replace table "$TABLE" "$prefix" dev "$dev" scope link src "$ip" || return 1
    done
    ip -4 route replace table "$TABLE" default via "$gw" dev "$dev" || return 1
    printf '%s %s %s\n' "$ip" "$dev" "$gw" > "$STATE/campus-route"
}
campus_sync() {
    command -v flock >/dev/null 2>&1 || return 1
    exec 9>"$LOCK" && flock -x 9 || return 1
    campus_sync_locked
    rc=$?
    flock -u 9 || true
    exec 9>&-
    return "$rc"
}
campus_clear() {
    command -v flock >/dev/null 2>&1 || return 1
    exec 9>"$LOCK" && flock -x 9 || return 1
    old=$(rule_ip)
    if [ -n "$old" ]; then
        ip -4 rule del pref "$PREF" from "$old/32" table "$TABLE" 2>/dev/null || true
        flush_owned_table || true
        rm -f "$STATE/campus-route"
    fi
    rc=0
    flock -u 9 || rc=1
    exec 9>&-
    return "$rc"
}
night() {
    /usr/sbin/mwan3 status 2>/dev/null | grep -Fq 'interface wanb is online' || return 1
    /sbin/ifdown wan
    campus_clear
}
morning() {
    /sbin/ifup wan
    n=0
    while [ "$n" -lt 18 ]; do
        sleep 10
        if campus_sync; then
            /usr/bin/campus-auth auto >/dev/null 2>&1 || true
            return 0
        fi
        n=$((n + 1))
    done
    return 1
}
case "$1" in
  sync-campus) campus_sync ;;
  clear-campus) campus_clear ;;
  night) night ;;
  morning) morning ;;
  *) exit 2 ;;
esac
