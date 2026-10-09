#!/bin/ash

PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
TAG=campus-auth
DIR=/tmp/campus-auth
CFG=campus-auth.main
mkdir -p "$DIR" || exit 1
chmod 700 "$DIR" 2>/dev/null

log() { logger -t "$TAG" "$*"; }

read_wan() {
    WAN_JSON=$(ubus call network.interface.wan status 2>/dev/null)
    WAN_UP=$(printf '%s' "$WAN_JSON" | jsonfilter -e '@.up' 2>/dev/null)
    WAN_IP=$(printf '%s' "$WAN_JSON" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    WAN_GW=$(printf '%s' "$WAN_JSON" | jsonfilter -e '@["route"][0].nexthop' 2>/dev/null)
    [ -n "$WAN_UP" ] || WAN_UP=unknown
    [ -n "$WAN_IP" ] || WAN_IP=none
    [ -n "$WAN_GW" ] || WAN_GW=none
}

probe_one() {
    endpoint=$1
    PROBE_CODE=000
    PROBE_EFFECTIVE=
    : > "$DIR/probe.headers"
    : > "$DIR/probe.body"
    /usr/lib/campus-auth/wan-health.sh sync-campus || return 1
    PROBE_RESULT=$(curl -4 --interface "$WAN_IP" -sS --connect-timeout 3 --max-time 8 --max-redirs 5 -L \
        -D "$DIR/probe.headers" -o "$DIR/probe.body" \
        -w '%{http_code}\n%{url_effective}' "$endpoint" 2>/dev/null)
    PROBE_CODE=$(printf '%s\n' "$PROBE_RESULT" | sed -n '1p')
    PROBE_EFFECTIVE=$(printf '%s\n' "$PROBE_RESULT" | sed -n '2p')
    [ -n "$PROBE_CODE" ] || PROBE_CODE=000
    [ -f "$DIR/probe.body" ] || : > "$DIR/probe.body"
    [ -f "$DIR/probe.headers" ] || : > "$DIR/probe.headers"
    chmod 600 "$DIR/probe.body" "$DIR/probe.headers" 2>/dev/null
}

has_type_b() {
    grep -Eiq 'loginVue|/api/loginVue/do' "$DIR/probe.body" "$DIR/probe.headers" 2>/dev/null ||
        printf '%s' "$PROBE_EFFECTIVE" | grep -Eiq 'loginVue|/api/loginVue/do'
}

has_type_a() {
    grep -Eiq 'eportal|InterFace\.do|index\.jsp|queryString|wlanuserip|/portal/portal-main' \
        "$DIR/probe.body" "$DIR/probe.headers" 2>/dev/null ||
        printf '%s' "$PROBE_EFFECTIVE" | grep -Eiq 'eportal|InterFace\.do|index\.jsp|/portal/portal-main'
}

extract_portal_url() {
    PORTAL_URL=
    case "$PROBE_EFFECTIVE" in
        *eportal*|*index.jsp*|*InterFace.do*|*/portal/portal-main*) PORTAL_URL=$PROBE_EFFECTIVE ;;
    esac
    if [ -z "$PORTAL_URL" ]; then
        PORTAL_URL=$(grep -Eio 'https?://[^"[:space:]<>]+' "$DIR/probe.body" 2>/dev/null |
            grep -Ei 'eportal|index\.jsp|InterFace\.do|/portal/portal-main' | head -n 1 | sed "s/['),;].*$//")
    fi
    if [ -z "$PORTAL_URL" ]; then
        relative_url=$(grep -Eo '/eportal/index\.jsp\?[^"[:space:]<>]+' "$DIR/probe.body" 2>/dev/null | head -n 1)
        case "$relative_url" in /eportal/index.jsp\?*) PORTAL_URL="https://zz.xtu.edu.cn$relative_url" ;; esac
    fi
    if [ -z "$PORTAL_URL" ]; then
        PORTAL_URL=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); v=$0} END {print v}' \
            "$DIR/probe.headers" 2>/dev/null)
    fi
}

capture_portal() {
    cp "$DIR/probe.headers" "$DIR/portal.headers" 2>/dev/null
    cp "$DIR/probe.body" "$DIR/portal.html" 2>/dev/null
    printf '%s\n' "$PORTAL_URL" > "$DIR/portal.url"
    date '+%F %T %z' > "$DIR/portal.time"
    chmod 600 "$DIR/portal.headers" "$DIR/portal.html" "$DIR/portal.url" "$DIR/portal.time" 2>/dev/null
}

detect_state() {
    read_wan
    PORTAL_URL=
    PORTAL_KIND=
    if [ "$WAN_UP" != true ] || [ "$WAN_IP" = none ]; then
        STATE=NO_WAN
        return
    fi
    for endpoint in \
        http://connectivitycheck.gstatic.com/generate_204 \
        http://www.msftconnecttest.com/connecttest.txt \
        http://www.baidu.com/ \
        http://neverssl.com/
    do
        probe_one "$endpoint"
        if [ "$PROBE_CODE" = 204 ]; then
            STATE=ONLINE
            return
        fi
        if has_type_b; then
            PORTAL_KIND=TYPE_B
            extract_portal_url
            capture_portal
            STATE=PORTAL_TYPE_B
            return
        fi
        if has_type_a; then
            PORTAL_KIND=TYPE_A
            extract_portal_url
            capture_portal
            if [ -n "$PORTAL_URL" ]; then
                STATE=PORTAL_TYPE_A
            else
                STATE=PORTAL_INCOMPLETE
            fi
            return
        fi
        if [ "$PROBE_CODE" = 200 ] &&
            printf '%s' "$PROBE_EFFECTIVE" | grep -qi 'msftconnecttest.com' &&
            grep -qi 'Microsoft Connect Test' "$DIR/probe.body" 2>/dev/null; then
            STATE=ONLINE
            return
        fi
    done
    STATE=UNKNOWN
}

report_state() {
    detect_state
    read_wan
    printf 'state=%s wan_up=%s wan_ip=%s gateway=%s\n' "$STATE" "$WAN_UP" "$WAN_IP" "$WAN_GW"
}

get_auth_config() {
    USERNAME=$(uci -q get "$CFG.username" 2>/dev/null)
    PASSWORD=$(uci -q get "$CFG.password" 2>/dev/null)
    SERVICE=$(uci -q get "$CFG.service" 2>/dev/null)
    [ -n "$SERVICE" ] || SERVICE=
}

login_request() {
    PORTAL_URL=$(printf '%s' "$PORTAL_URL" | sed 's/ /%20/g')
    case "$PORTAL_URL" in
        https://zz.xtu.edu.cn:443/*) PORTAL_URL=https://zz.xtu.edu.cn${PORTAL_URL#https://zz.xtu.edu.cn:443} ;;
    esac
    case "$PORTAL_URL" in
        https://zz.xtu.edu.cn/eportal/index.jsp\?*|https://zz.xtu.edu.cn/portal/portal-main\?*) ;;
        *)
            log "PORTAL_TYPE_A_UNSUPPORTED_PATH"
            echo "Portal URL is not the verified XTU portal entry; no login request sent."
            return 2
            ;;
    esac
    if ! /usr/lib/campus-auth/wan-health.sh sync-campus; then
        log 'CAMPUS_SOURCE_ROUTE_FAILED'
        return 1
    fi
    /usr/lib/campus-auth/campus-auth-modern.sh
}

classify_auth_response_value() {
    value=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case "$value" in
        *notfound*|*not_found*|*404*) echo not_found ;;
        *captcha*|*validcode*) echo captcha_required ;;
        *credential*|*password*|*account*|*username*|*user*) echo credential_rejected ;;
        *redirect*) echo redirect ;;
        success|succeed|accepted|ok|true|1|0|200) echo accepted ;;
        *fail*|*error*|*denied*|*invalid*) echo rejected ;;
        *) echo other ;;
    esac
}

summarize_auth_response() {
    http_code=$1
    response_file=$2
    summary=
    for field in result message error; do
        value=$(jsonfilter -e "@.$field" < "$response_file" 2>/dev/null || true)
        [ -n "$value" ] || continue
        category=$(classify_auth_response_value "$value")
        [ -z "$summary" ] || summary="$summary,"
        summary="$summary$field:$category"
    done
    if [ -n "$summary" ]; then
        printf '%s' "$summary"
    else
        case "$http_code" in
            404) printf 'not_found' ;;
            000) printf 'transport_error' ;;
            *) [ -s "$response_file" ] && printf 'non_json' || printf 'empty' ;;
        esac
    fi
}

retry_allowed() {
    today=$(date '+%Y%m%d')
    now=$(date +%s)
    retry_day=
    retry_count=0
    retry_after=0
    if [ -r "$DIR/retry.state" ]; then
        read -r retry_day retry_count retry_after < "$DIR/retry.state"
    fi
    if [ "$retry_day" != "$today" ]; then
        retry_count=0
        retry_after=0
    fi
    case "$retry_count" in ''|*[!0-9]*) retry_count=0 ;; esac
    case "$retry_after" in ''|*[!0-9]*) retry_after=0 ;; esac
    if [ "$now" -lt "$retry_after" ]; then
        return 1
    fi
    retry_count=$((retry_count + 1))
    case "$retry_count" in
        1) delay=300 ;;
        2) delay=600 ;;
        3) delay=1200 ;;
        4) delay=1800 ;;
        *) delay=1800 ;;
    esac
    printf '%s %s %s\n' "$today" "$retry_count" "$((now + delay))" > "$DIR/retry.state"
    chmod 600 "$DIR/retry.state"
    return 0
}

activate_after_success() {
    [ "$(uci -q get "$CFG.bootstrap_pending" 2>/dev/null)" = 1 ] || return 0
    install_runtime_triggers || {
        log "TRIGGER_INSTALL_FAILED"
        return 1
    }
    uci set "$CFG.bootstrap_pending=0" || return 1
    uci set "$CFG.enabled=1" || return 1
    uci commit campus-auth || return 1
    /etc/init.d/campus-auth enable >/dev/null 2>&1
    /etc/init.d/campus-auth start >/dev/null 2>&1
    log "BOOTSTRAP_TEST_PASSED service_enabled"
}

install_runtime_triggers() {
    hotplug_tmp=/etc/hotplug.d/iface/.95-campus-auth.$$
    cron_tmp=/etc/crontabs/.root-campus-auth.$$
    mkdir -p /etc/hotplug.d/iface /etc/crontabs || return 1
    cp /usr/lib/campus-auth/95-campus-auth "$hotplug_tmp" || return 1
    chmod 700 "$hotplug_tmp" || return 1
    mv -f "$hotplug_tmp" /etc/hotplug.d/iface/95-campus-auth || return 1
    if [ -r /etc/crontabs/root ]; then
        grep -v 'CAMPUS_AUTH_' /etc/crontabs/root > "$cron_tmp" || :
    else
        : > "$cron_tmp"
    fi
    {
        printf '%s\n' '*/5 * * * * /usr/bin/campus-auth auto >/dev/null 2>&1 # CAMPUS_AUTH_WATCHDOG'
    } >> "$cron_tmp" || return 1
    chmod 600 "$cron_tmp" || return 1
    mv -f "$cron_tmp" /etc/crontabs/root || return 1
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    return 0
}

maybe_recover_wan() {
    now=$(date +%s)
    first_seen=
    last_action=0
    stage=
    [ -r "$DIR/no-wan.state" ] && read -r first_seen last_action stage < "$DIR/no-wan.state"
    case "$first_seen" in ''|*[!0-9]*) first_seen=$now; last_action=0; stage= ;; esac
    case "$last_action" in ''|*[!0-9]*) last_action=0 ;; esac
    case "$stage" in renew|ifup) ;; *) stage= ;; esac
    if [ "$stage" = ifup ]; then interval=900; else interval=300; fi
    if [ $((now - first_seen)) -lt 300 ] || [ $((now - last_action)) -lt "$interval" ]; then
        printf '%s %s %s\n' "$first_seen" "$last_action" "$stage" > "$DIR/no-wan.state"
        chmod 600 "$DIR/no-wan.state"
        return 0
    fi
    if [ -z "$stage" ]; then
        ubus call network.interface.wan renew >/dev/null 2>&1
        stage=renew
        log "WAN_RENEW_ATTEMPT"
    else
        ifup wan >/dev/null 2>&1
        stage=ifup
        log "WAN_IFUP_ATTEMPT"
    fi
    printf '%s %s %s\n' "$first_seen" "$now" "$stage" > "$DIR/no-wan.state"
    chmod 600 "$DIR/no-wan.state"
}

run_auto() {
    enabled=$(uci -q get "$CFG.enabled" 2>/dev/null)
    bootstrap=$(uci -q get "$CFG.bootstrap_pending" 2>/dev/null)
    if [ "$enabled" != 1 ] && [ "$bootstrap" != 1 ]; then
        echo "DISABLED"
        return 0
    fi
    hour=$(date '+%H')
    hour=$(printf '%s' "$hour" | sed 's/^0//')
    [ -n "$hour" ] || hour=0
    if [ "$hour" -lt 6 ] && { [ "$enabled" = 1 ] || [ "$bootstrap" = 1 ]; }; then
        echo "NIGHT_WINDOW"
        return 0
    fi
    detect_state
    case "$STATE" in
        ONLINE) rm -f "$DIR/retry.state" "$DIR/no-wan.state"; echo "ONLINE"; return 0 ;;
        NO_WAN) maybe_recover_wan; echo "NO_WAN"; return 0 ;;
        PORTAL_TYPE_B|PORTAL_INCOMPLETE|UNKNOWN)
            log "$STATE no_login"
            echo "$STATE"
            return 0
            ;;
        CAPTCHA_REQUIRED)
            log "CAPTCHA_REQUIRED"
            echo "CAPTCHA_REQUIRED"
            return 1
            ;;
        PORTAL_TYPE_A) ;;
        *) echo "$STATE"; return 0 ;;
    esac

    if [ "$hour" -lt 6 ]; then
        echo "PORTAL_WAIT_UNTIL_0600"
        return 0
    fi
    rm -f "$DIR/no-wan.state"
    get_auth_config
    if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
        log "CREDENTIALS_MISSING"
        echo "CREDENTIALS_MISSING"
        return 1
    fi
    if ! retry_allowed; then
        echo "BACKOFF"
        return 0
    fi
    if login_request; then
        rm -f "$DIR/retry.state"
        activate_after_success
        return 0
    fi
    return 1
}

run_locked() {
    command=$1
    shift
    flock -n "$DIR/auth.lock" "$0" "_locked_$command" "$@"
}

case "$1" in
    status|check|diagnose)
        report_state
        ;;
    login|auto)
        run_locked "$1"
        ;;
    daemon)
        while :; do
            "$0" auto >/dev/null 2>&1
            sleep 60
        done
        ;;
    _locked_auto)
        run_auto
        ;;
    _locked_login)
        detect_state
        case "$STATE" in
            ONLINE) rm -f "$DIR/retry.state" "$DIR/no-wan.state"; echo "ONLINE; no login request sent."; exit 0 ;;
            PORTAL_TYPE_A) ;;
            CAPTCHA_REQUIRED) log "CAPTCHA_REQUIRED"; echo "CAPTCHA_REQUIRED"; exit 1 ;;
            *) echo "$STATE; no login request sent."; exit 1 ;;
        esac
        get_auth_config
        if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
            echo "CREDENTIALS_MISSING"
            exit 1
        fi
        if retry_allowed; then
            login_request
            rc=$?
            [ "$rc" -eq 0 ] && rm -f "$DIR/retry.state"
            exit "$rc"
        fi
        echo "BACKOFF"
        exit 1
        ;;
    *)
        echo "Usage: campus-auth {status|check|diagnose|login|auto|daemon}"
        exit 2
        ;;
esac

