#!/bin/ash
# Modern XTU portal adapter. Invoked by campus-auth.sh only after a captive
# portal redirect was captured. Credentials and transient portal tokens stay
# in mode-0600 files under /tmp/campus-auth; stdout/syslog contain categories.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
DIR=/tmp/campus-auth
ORIGIN=https://zz.xtu.edu.cn
SSO=$ORIGIN/cas-sso
API=$ORIGIN/api/aggregation

log() { logger -t campus-auth "$*"; }
fail() { log "$1"; echo "$1"; return 1; }

urlencode() {
    LC_ALL=C
    ue_in=$1
    ue_out=
    while [ -n "$ue_in" ]; do
        ue_char=${ue_in%"${ue_in#?}"}
        ue_in=${ue_in#?}
        case "$ue_char" in
            [a-zA-Z0-9._~-]) ue_out=$ue_out$ue_char ;;
            *) ue_num=$(printf '%d' "'$ue_char") || return 1
               ue_hex=$(printf '%%%02X' "$ue_num") || return 1
               ue_out=$ue_out$ue_hex ;;
        esac
    done
    printf '%s' "$ue_out"
}

write_post_config() {
    wp_url=$1
    wp_body=$2
    wp_conf=$3
    {
        printf 'url = "%s"\n' "$wp_url"
        printf 'request = "POST"\n'
        printf 'header = "Content-Type: application/json"\n'
        printf 'header = "Accept: application/json, text/plain, */*"\n'
        printf 'cookie = "%s/cas.cookies"\n' "$DIR"
        printf 'cookie-jar = "%s/cas.cookies"\n' "$DIR"
        printf 'data-binary = "@%s"\n' "$wp_body"
        printf 'connect-timeout = 3\nmax-time = 10\nsilent\nshow-error\n'
    } > "$wp_conf"
    chmod 600 "$wp_conf"
}

api_post() {
    ap_url=$1
    ap_body=$2
    ap_name=$3
    ap_conf=$DIR/$ap_name.conf
    write_post_config "$ap_url" "$ap_body" "$ap_conf" || return 1
    ap_code=$(curl -4 --interface "$WAN_IP" --config "$ap_conf" \
        -D "$DIR/$ap_name.headers" -o "$DIR/$ap_name.json" -w '%{http_code}' 2>/dev/null) || ap_code=000
    rm -f "$ap_conf"
    chmod 600 "$DIR/$ap_name.headers" "$DIR/$ap_name.json" 2>/dev/null || true
    [ -n "$ap_code" ] || ap_code=000
    ap_appcode=$(jsonfilter -e '@.code' < "$DIR/$ap_name.json" 2>/dev/null || true)
}

get_node() {
    . /usr/share/libubox/jshn.sh
    json_init
    json_add_string sessionId "$SESSION_ID"
    json_add_string flowKey "$FLOW_KEY"
    json_dump > "$DIR/node.request"
    chmod 600 "$DIR/node.request"
    api_post "$ORIGIN/eportal/workFlow/getCurrentNode" "$DIR/node.request" current-node
    [ "$ap_code" = 200 ] && [ "$ap_appcode" = 200 ] || return 1
    NODE_PATH=$(jsonfilter -e '@.data.currentNodePath' < "$DIR/current-node.json" 2>/dev/null)
    [ -n "$NODE_PATH" ] || NODE_PATH=$(jsonfilter -e '@.currentNodePath' < "$DIR/current-node.json" 2>/dev/null)
    [ -n "$NODE_PATH" ]
}

write_session_body() {
    wb_file=$1
    wb_key=${2-}
    wb_value=${3-}
    . /usr/share/libubox/jshn.sh
    json_init
    json_add_string sessionId "$SESSION_ID"
    [ -z "$wb_key" ] || json_add_string "$wb_key" "$wb_value"
    json_dump > "$wb_file"
    chmod 600 "$wb_file"
}

cleanup_private() {
    rm -f "$DIR/cas.cookies" "$DIR/cas-get.conf" "$DIR/cas-get.headers" \
        "$DIR/cas-login.html" "$DIR/captcha-get.conf" "$DIR/captcha.headers" \
        "$DIR/captcha.json" "$DIR/cas-post.conf" "$DIR/cas-post.headers" \
        "$DIR/cas-post.body" "$DIR/cas-callback.conf" "$DIR/cas-callback.headers" \
        "$DIR/cas-callback.body" "$DIR/cas-callback.code" "$DIR/croypto.b64" \
        "$DIR/password.plain" "$DIR/password.enc" "$DIR/captcha.plain" \
        "$DIR/captcha-payload.enc" "$DIR/username.plain" "$DIR/node.request" \
        "$DIR/current-node.conf" "$DIR/current-node.headers" "$DIR/current-node.json" \
        "$DIR/device-auth.request" "$DIR/device-auth.conf" "$DIR/device-auth.headers" \
        "$DIR/device-auth.json" "$DIR/device-result.request" "$DIR/device-result.conf" \
        "$DIR/device-result.headers" "$DIR/device-result.json" "$DIR/services.request" \
        "$DIR/services.conf" "$DIR/services.headers" "$DIR/services.json" \
        "$DIR/service-login.request" "$DIR/service-login.conf" \
        "$DIR/service-login.headers" "$DIR/service-login.json" \
        "$DIR/https-check.body" "$DIR/msft-check.body" \
        "$DIR/portal-hop.conf" "$DIR/portal-hop.headers" "$DIR/portal-hop.body"
}

form_get_config() {
    fg_url=$1
    fg_conf=$2
    {
        printf 'url = "%s"\n' "$fg_url"
        printf 'cookie = "%s/cas.cookies"\n' "$DIR"
        printf 'cookie-jar = "%s/cas.cookies"\n' "$DIR"
        printf 'connect-timeout = 3\nmax-time = 10\nsilent\nshow-error\n'
    } > "$fg_conf"
    chmod 600 "$fg_conf"
}

fresh_portal_values() {
    portal_reason=UNKNOWN
    ENTRY_URL=$PORTAL_URL
    case "$PORTAL_URL" in
        https://zz.xtu.edu.cn:443/*) PORTAL_URL=$ORIGIN${PORTAL_URL#https://zz.xtu.edu.cn:443} ;;
    esac
    case "$PORTAL_URL" in
        https://zz.xtu.edu.cn/eportal/index.jsp\?*|https://zz.xtu.edu.cn/portal/portal-main\?*) ;;
        *) portal_reason=INPUT_URL; return 1 ;;
    esac
    current_url=$(printf '%s' "$PORTAL_URL" | sed 's/ /%20/g')
    portal_ready=0
    hop=0
    while [ "$hop" -lt 4 ]; do
        hop=$((hop + 1))
        fg_conf=$DIR/portal-hop.conf
        form_get_config "$current_url" "$fg_conf" || { portal_reason=GET_CONFIG; return 1; }
        hop_code=$(curl --globoff -4 --interface "$WAN_IP" --config "$fg_conf" \
            -D "$DIR/portal-hop.headers" -o "$DIR/portal-hop.body" -w '%{http_code}' 2>/dev/null) || hop_code=000
        rm -f "$fg_conf"
        chmod 600 "$DIR/portal-hop.headers" "$DIR/portal-hop.body" 2>/dev/null || true
        case "$hop_code" in
            301|302|303|307|308)
                next_url=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); loc=$0} END {print loc}' "$DIR/portal-hop.headers" | sed 's/ /%20/g')
                case "$next_url" in
                    https://zz.xtu.edu.cn:443/*) current_url=$ORIGIN${next_url#https://zz.xtu.edu.cn:443} ;;
                    https://zz.xtu.edu.cn/*) current_url=$next_url ;;
                    /*) case "$next_url" in //*) portal_reason=REDIRECT_SCHEME_RELATIVE; return 1 ;; esac; current_url=$ORIGIN$next_url ;;
                    *) portal_reason=REDIRECT_ORIGIN; return 1 ;;
                esac
                continue
                ;;
            200)
                case "$current_url" in
                    https://zz.xtu.edu.cn/portal/portal-main\?*)
                        PORTAL_URL=$current_url
                        portal_ready=1
                        break
                        ;;
                    *)
                        next_url=$(grep -Eo 'https://zz\.xtu\.edu\.cn/[^" <>]+' "$DIR/portal-hop.body" 2>/dev/null | head -n 1)
                        case "$next_url" in https://zz.xtu.edu.cn/portal/portal-main\?*) current_url=$next_url ;; *) portal_reason=SHELL_TARGET; return 1 ;; esac
                        ;;
                esac
                ;;
            *) portal_reason=HOP_HTTP_$hop_code; return 1 ;;
        esac
    done
    rm -f "$DIR/portal-hop.headers" "$DIR/portal-hop.body"
    [ "$portal_ready" = 1 ] || { portal_reason=HOP_LIMIT; return 1; }
    pquery=${PORTAL_URL#*\?}
    get_param() { printf '%s' "$pquery" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1; }
    query_param() { qp=${1#*\?}; printf '%s' "$qp" | tr '&' '\n' | sed -n "s/^$2=//p" | head -n 1; }
    url_decode() {
        decoded=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/%/\\x/g; s/+/ /g')
        printf '%b' "$decoded"
    }
    SESSION_ID=$(url_decode "$(get_param sessionId)")
    USER_IP=$(url_decode "$(get_param userIp)")
    NAS_IP=$(url_decode "$(get_param nasIp)")
    USER_MAC=$(url_decode "$(get_param userMac)")
    CAS_SESSION_RAW=$(get_param sessionId)
    CAS_CUSTOM_PAGE=$(get_param customPageId)
    CAS_SSID=$(get_param ssid)
    [ -n "$CAS_SSID" ] || CAS_SSID=$(query_param "$ENTRY_URL" ssid)
    CAS_NODE_MAC=$(get_param nodeMac)
    [ -n "$CAS_NODE_MAC" ] || CAS_NODE_MAC=$(get_param userMac)
    CAS_MODE=$(get_param mode)
    [ -n "$CAS_MODE" ] || CAS_MODE=$(query_param "$ENTRY_URL" mode)
    CAS_LANGUAGE=$(get_param language)
    [ -n "$CAS_LANGUAGE" ] || CAS_LANGUAGE=$(query_param "$ENTRY_URL" language)
    CAS_PREVIEW=$(get_param preview)
    [ -n "$CAS_PREVIEW" ] || CAS_PREVIEW=$(query_param "$ENTRY_URL" preview)
    [ -n "$CAS_LANGUAGE" ] || CAS_LANGUAGE=zh-CN
    case "$CAS_LANGUAGE" in zh-CN|en-US) ;; *) portal_reason=LANGUAGE_INVALID; return 1 ;; esac
    [ -n "$CAS_PREVIEW" ] || CAS_PREVIEW=false
    case "$CAS_PREVIEW" in true|false) ;; *) portal_reason=PREVIEW_INVALID; return 1 ;; esac
    CAS_TIMER=$(($(date +%s) * 1000))
    FLOW_KEY=$(url_decode "$(get_param flowKey)")
    [ -n "$FLOW_KEY" ] || FLOW_KEY=portal_auth
    case "$SESSION_ID" in ''|*[!A-Za-z0-9._~-]*) portal_reason=SESSION_ID_INVALID; return 1 ;; esac
    case "$USER_IP" in *[!0-9.]*) portal_reason=USER_IP_INVALID; return 1 ;; esac
    case "$NAS_IP" in *[!0-9.]*) portal_reason=NAS_IP_INVALID; return 1 ;; esac
    case "$USER_MAC" in *[!A-Fa-f0-9:-]*) portal_reason=USER_MAC_INVALID; return 1 ;; esac
    case "$FLOW_KEY" in *[!A-Za-z0-9._~-]*) portal_reason=FLOW_KEY_INVALID; return 1 ;; esac
    [ -n "$USER_IP" ] && [ -n "$NAS_IP" ] && [ -n "$USER_MAC" ] || { portal_reason=REQUIRED_QUERY_MISSING; return 1; }
}

html_field_text() {
    hf_id=$1
    hf_file=$2
    awk -v id="$hf_id" '
      BEGIN { active=0; waiting=0; value=""; key="id=\"" id "\"" }
      {
        line=$0
        if (!active) {
          pos=index(line,key)
          if (!pos) next
          active=1
          line=substr(line,pos)
          gt=index(line,">")
          if (!gt) { waiting=1; next }
          line=substr(line,gt+1)
        } else if (waiting) {
          gt=index(line,">")
          if (!gt) next
          line=substr(line,gt+1)
          waiting=0
        }
        close_pos=index(line,"</")
        if (close_pos) line=substr(line,1,close_pos-1)
        gsub(/<[^>]*>/,"",line)
        value=value " " line
        if (close_pos) {
          gsub(/^[[:space:]]+/,"",value)
          gsub(/[[:space:]]+$/,"",value)
          print value
          exit
        }
      }
    ' "$hf_file"
}

cas_login() {
    cas_url="$SSO/login?flowSessionId=$CAS_SESSION_RAW&customPageId=$CAS_CUSTOM_PAGE&preview=$CAS_PREVIEW&appType=normal&language=$CAS_LANGUAGE&timer=$CAS_TIMER"
    [ -z "$CAS_MODE" ] || cas_url="$cas_url&mode=$CAS_MODE"
    [ -z "$NAS_IP" ] || cas_url="$cas_url&nasIp=$(get_param nasIp)"
    [ -z "$USER_IP" ] || cas_url="$cas_url&userIp=$(get_param userIp)"
    [ -z "$CAS_SSID" ] || cas_url="$cas_url&ssid=$CAS_SSID"
    [ -z "$CAS_NODE_MAC" ] || cas_url="$cas_url&nodeMac=$CAS_NODE_MAC"
    cas_conf=$DIR/cas-get.conf
    form_get_config "$cas_url" "$cas_conf" || return 1
    cas_code=$(curl --globoff -4 --interface "$WAN_IP" --config "$cas_conf" \
        -D "$DIR/cas-get.headers" -o "$DIR/cas-login.html" -w '%{http_code}' 2>/dev/null) || cas_code=000
    chmod 600 "$DIR/cas-get.headers" "$DIR/cas-login.html" 2>/dev/null || true
    rm -f "$cas_conf"
    [ "$cas_code" = 200 ] || { log "CAS_PAGE_FAILED http=$cas_code"; return 1; }

    execution=$(sed -n 's/.*id="login-page-flowkey"[^>]*>\([^<]*\)<.*/\1/p' "$DIR/cas-login.html" | head -n 1)
    croypto=$(sed -n 's/.*id="login-croypto"[^>]*>\([^<]*\)<.*/\1/p' "$DIR/cas-login.html" | head -n 1)
    [ -n "$execution" ] && [ -n "$croypto" ] || { log 'CAS_CHALLENGE_MISSING'; return 1; }

    # The public page calls getCount(username) before showing a captcha. It
    # double-encodes userName through encodeURIComponent + HttpParams.
    # A 401/no data follows the page's empty-object fallback; true means stop.
    enc_user=$(urlencode "$(urlencode "$USERNAME")") || return 1
    cat > "$DIR/captcha-get.conf" <<EOF
url = "$SSO/api/protected/user/captchaCount/validate?userName=$enc_user"
cookie = "$DIR/cas.cookies"
cookie-jar = "$DIR/cas.cookies"
connect-timeout = 3
max-time = 8
silent
show-error
EOF
    chmod 600 "$DIR/captcha-get.conf"
    curl --globoff -4 --interface "$WAN_IP" --config "$DIR/captcha-get.conf" \
        -D "$DIR/captcha.headers" -o "$DIR/captcha.json" 2>/dev/null || true
    chmod 600 "$DIR/captcha.headers" "$DIR/captcha.json" 2>/dev/null || true
    rm -f "$DIR/captcha-get.conf"
    captcha_required=$(jsonfilter -e '@.data.captchaInvisible' < "$DIR/captcha.json" 2>/dev/null || true)
    case "$captcha_required" in true|1|yes) log 'CAPTCHA_REQUIRED'; return 1 ;; esac

    # croypto is base64 for a 16-byte AES key. Convert its public challenge
    # representation to hex without requiring an od/hexdump applet.
    printf '%s' "$croypto" > "$DIR/croypto.b64"
    keyhex=$(awk '
      BEGIN { alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" }
      { s=$0; gsub(/[\r\n \t]/,"",s); if (length(s)!=24) exit 2;
        for (i=1;i<=length(s);i+=4) {
          a=index(alphabet,substr(s,i,1))-1; b=index(alphabet,substr(s,i+1,1))-1;
          c=substr(s,i+2,1)=="=" ? 0 : index(alphabet,substr(s,i+2,1))-1;
          d=substr(s,i+3,1)=="=" ? 0 : index(alphabet,substr(s,i+3,1))-1;
          if (a<0 || b<0 || c<0 || d<0) exit 2;
          printf "%02x", a*4+int(b/16);
          if (substr(s,i+2,1)!="=") printf "%02x", (b%16)*16+int(c/4);
          if (substr(s,i+3,1)!="=") printf "%02x", (c%4)*64+d;
        }
      }' "$DIR/croypto.b64") || { log 'CAS_KEY_PARSE_FAILED'; return 1; }
    [ "${#keyhex}" = 32 ] || { log 'CAS_KEY_LENGTH_UNSUPPORTED'; return 1; }

    printf '%s' "$PASSWORD" > "$DIR/password.plain"
    printf '{}' > "$DIR/captcha.plain"
    openssl enc -aes-128-ecb -K "$keyhex" -nosalt -a -A -in "$DIR/password.plain" -out "$DIR/password.enc" 2>/dev/null || return 1
    openssl enc -aes-128-ecb -K "$keyhex" -nosalt -a -A -in "$DIR/captcha.plain" -out "$DIR/captcha-payload.enc" 2>/dev/null || return 1
    chmod 600 "$DIR/password.plain" "$DIR/captcha.plain" "$DIR/password.enc" "$DIR/captcha-payload.enc" "$DIR/croypto.b64"

    # Keep all account material in the private curl config and files.
    cat > "$DIR/cas-post.conf" <<EOF
url = "$cas_url&accept-language=zh-CN"
request = "POST"
referer = "$cas_url"
cookie = "$DIR/cas.cookies"
cookie-jar = "$DIR/cas.cookies"
header = "Content-Type: application/x-www-form-urlencoded; charset=UTF-8"
header = "Origin: https://zz.xtu.edu.cn"
header = "Accept: text/html,application/xhtml+xml"
data-urlencode = "type=UsernamePassword"
data-urlencode = "_eventId=submit"
data-urlencode = "geolocation="
data-urlencode = "execution=$execution"
data-urlencode = "croypto=$croypto"
data-urlencode = "username@$DIR/username.plain"
data-urlencode = "password@$DIR/password.enc"
data-urlencode = "captcha_code="
data-urlencode = "captcha_payload@$DIR/captcha-payload.enc"
connect-timeout = 3
max-time = 12
silent
show-error
EOF
    printf '%s' "$USERNAME" > "$DIR/username.plain"
    chmod 600 "$DIR/cas-post.conf" "$DIR/username.plain"
    cas_post_code=$(curl -4 --interface "$WAN_IP" --config "$DIR/cas-post.conf" \
        -D "$DIR/cas-post.headers" -o "$DIR/cas-post.body" -w '%{http_code}' 2>/dev/null) || cas_post_code=000
    chmod 600 "$DIR/cas-post.headers" "$DIR/cas-post.body" 2>/dev/null || true
    rm -f "$DIR/cas-post.conf" "$DIR/password.plain" "$DIR/password.enc" \
        "$DIR/captcha.plain" "$DIR/captcha-payload.enc" "$DIR/username.plain" "$DIR/croypto.b64"
    [ "$cas_post_code" = 302 ] || {
        if [ "${CAMPUS_AUTH_DIAGNOSTIC_KEEP_BODY:-0}" = 1 ]; then
            cp "$DIR/cas-post.body" "$DIR/cas-diagnostic.private" 2>/dev/null || true
            chmod 600 "$DIR/cas-diagnostic.private" 2>/dev/null || true
        fi
        response_code=$(jsonfilter -e '@.code' < "$DIR/cas-post.body" 2>/dev/null || true)
        case "$response_code" in ''|*[!0-9]*) response_code= ;; esac
        error_code_text=$(html_field_text login-error-code "$DIR/cas-post.body")
        if [ -z "$response_code" ]; then
            response_code=$error_code_text
        fi
        error_code_dom=no
        [ -z "$error_code_text" ] || error_code_dom=yes
        error_message=$(html_field_text login-error-msg "$DIR/cas-post.body" | sed 's/&nbsp;/ /g; s/&#32;/ /g; s/&#x20;/ /g; s/&#X20;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')
        error_msg_dom=no
        [ -z "$error_message" ] || error_msg_dom=yes
        case "$response_code" in ''|*[!0-9]*) response_code= ;; esac
        if [ -z "$response_code" ]; then
            case "$error_message" in ''|*[!0-9]*) response_code=unknown ;; *) response_code=$error_message ;; esac
        fi
        error_message=$(printf '%s' "$error_message" | tr 'A-Z' 'a-z')
        account_password_invalid=no
        account_locked=no
        execution_expired=no
        captcha_required=no
        case "$response_code" in
            1030027|1030031) account_password_invalid=yes ;;
            1030028) account_locked=yes ;;
        esac
        case "$error_message" in
            *execution*expired*|*execution*timeout*|*session*expired*) execution_expired=yes ;;
        esac
        case "$error_message" in
            *captcha*|*validcode*|*verification*code*) captcha_required=yes ;;
        esac
        content_type=$(awk 'tolower($1)=="content-type:" {sub(/\r$/,""); sub(/;.*/,"",$2); print tolower($2); exit}' "$DIR/cas-post.headers")
        case "$content_type" in text/html|application/json|application/xhtml+xml) ;; *) content_type=other ;; esac
        log "CAS_LOGIN_REJECTED http=$cas_post_code type=${content_type:-unknown} code=$response_code code_dom=$error_code_dom message_dom=$error_msg_dom account_password_invalid=$account_password_invalid account_locked=$account_locked execution_expired=$execution_expired captcha_required=$captcha_required"
        return 1
    }

    # Follow only the observed same-origin auth-success callback; never allow
    # curl to follow an unvalidated redirect to another host.
    location=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); loc=$0} END {print loc}' "$DIR/cas-post.headers" | sed 's/ /%20/g')
    case "$location" in
        https://zz.xtu.edu.cn:443/*) callback_url=$ORIGIN${location#https://zz.xtu.edu.cn:443} ;;
        https://zz.xtu.edu.cn/*) callback_url=$location ;;
        /*) callback_url=$ORIGIN$location ;;
        *) log 'CAS_REDIRECT_UNSAFE'; return 1 ;;
    esac
    case "$callback_url" in https://zz.xtu.edu.cn/*) ;; *) log 'CAS_REDIRECT_UNSAFE'; return 1 ;; esac
    callback_hops=0
    callback_done=0
    while [ "$callback_hops" -lt 4 ]; do
        callback_hops=$((callback_hops + 1))
        cat > "$DIR/cas-callback.conf" <<EOF
url = "$callback_url"
cookie = "$DIR/cas.cookies"
cookie-jar = "$DIR/cas.cookies"
connect-timeout = 3
max-time = 10
silent
show-error
EOF
        chmod 600 "$DIR/cas-callback.conf"
        callback_code=$(curl --globoff -4 --interface "$WAN_IP" --config "$DIR/cas-callback.conf" \
            -D "$DIR/cas-callback.headers" -o "$DIR/cas-callback.body" -w '%{http_code}' 2>/dev/null) || callback_code=000
        chmod 600 "$DIR/cas-callback.headers" "$DIR/cas-callback.body" 2>/dev/null || true
        case "$callback_url" in
            https://zz.xtu.edu.cn/portal/auth-success*|https://zz.xtu.edu.cn/portal/assets/auth-success.html|https://zz.xtu.edu.cn/portal/assets/auth-success.html\?*)
                [ "$callback_code" = 200 ] || { log "AUTH_SUCCESS_CALLBACK_FAILED http=$callback_code"; return 1; }
                callback_done=1
                break
                ;;
        esac
        case "$callback_code" in
            301|302|303|307|308) ;;
            *)
                if [ "${CAMPUS_AUTH_DIAGNOSTIC_KEEP_BODY:-0}" = 1 ]; then
                    cp "$DIR/cas-callback.body" "$DIR/callback-diagnostic.private" 2>/dev/null || true
                    cp "$DIR/cas.cookies" "$DIR/callback-cookies.private" 2>/dev/null || true
                    printf '%s\n' "$callback_url" > "$DIR/callback-url.private"
                    printf '%s\n%s\n%s\n' "$SESSION_ID" "$FLOW_KEY" "$WAN_IP" > "$DIR/callback-context.private"
                    chmod 600 "$DIR"/callback-*.private 2>/dev/null || true
                fi
                log "CAS_REDIRECT_FAILED http=$callback_code"
                return 1
                ;;
        esac
        next_url=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); loc=$0} END {print loc}' "$DIR/cas-callback.headers" | sed 's/ /%20/g')
        case "$next_url" in
            https://zz.xtu.edu.cn:443/*) callback_url=$ORIGIN${next_url#https://zz.xtu.edu.cn:443} ;;
            https://zz.xtu.edu.cn/*) callback_url=$next_url ;;
            /*) case "$next_url" in //*) log 'CAS_REDIRECT_UNSAFE'; return 1 ;; esac; callback_url=$ORIGIN$next_url ;;
            *) log 'CAS_REDIRECT_UNSAFE'; return 1 ;;
        esac
    done
    [ "$callback_done" = 1 ] || { log 'CAS_REDIRECT_LIMIT'; return 1; }
    rm -f "$DIR/cas-callback.conf" "$DIR/cas-post.body" "$DIR/cas-post.headers" "$DIR/cas-login.html"
    return 0
}

modern_login() {
    trap cleanup_private EXIT
    trap 'exit 1' HUP INT TERM
    WAN_JSON=$(ubus call network.interface.wan status 2>/dev/null)
    WAN_IP=$(printf '%s' "$WAN_JSON" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    [ -n "$WAN_IP" ] || { fail 'NO_CAMPUS_WAN_IP'; return 1; }
    USERNAME=$(uci -q get campus-auth.main.username 2>/dev/null)
    PASSWORD=$(uci -q get campus-auth.main.password 2>/dev/null)
    SERVICE=$(uci -q get campus-auth.main.service 2>/dev/null)
    [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || { fail 'CREDENTIALS_MISSING'; return 1; }
    /usr/lib/campus-auth/wan-health.sh sync-campus || { fail 'CAMPUS_SOURCE_ROUTE_FAILED'; return 1; }
    PORTAL_URL=$(cat "$DIR/portal.url" 2>/dev/null)
    fresh_portal_values || { fail "PORTAL_SESSION_UNAVAILABLE:${portal_reason:-UNKNOWN}"; return 1; }
    cas_login || return 1

    # The active auth-success frontend sets its completion flag and calls the
    # ordinary workflow-node API. It does not invoke the older SID exchange or
    # submit credentials a second time.
    case "$callback_done:$callback_url" in
        1:https://zz.xtu.edu.cn/portal/auth-success*|1:https://zz.xtu.edu.cn/portal/assets/auth-success.html|1:https://zz.xtu.edu.cn/portal/assets/auth-success.html\?*) ;;
        *) log 'CAS_SUCCESS_CALLBACK_UNEXPECTED'; return 1 ;;
    esac
    get_node || { log "WORKFLOW_NODE_FAILED http=$ap_code"; return 1; }
    steps=0
    workflow_finished=0
    while [ "$steps" -lt 7 ]; do
        steps=$((steps + 1))
        case "$NODE_PATH" in
            deviceAuthentication)
                write_session_body "$DIR/device-auth.request" || return 1
                api_post "$ORIGIN/eportal/network/deviceAuthentication" "$DIR/device-auth.request" device-auth
                [ "$ap_code" = 200 ] && [ "$ap_appcode" = 200 ] || { log "DEVICE_AUTH_START_FAILED http=$ap_code"; return 1; }
                device_message=$(jsonfilter -e '@.message' < "$DIR/device-auth.json" 2>/dev/null | tr 'A-Z' 'a-z' || true)
                case "$device_message" in *cpweb*|*wifidog*) log 'DEVICE_AUTH_BRANCH_UNSUPPORTED'; return 1 ;; esac
                tries=0
                device_online=
                device_error=
                while [ "$tries" -lt 30 ]; do
                    write_session_body "$DIR/device-result.request" || return 1
                    api_post "$ORIGIN/eportal/network/deviceAuthResult" "$DIR/device-result.request" device-result
                    [ "$ap_code" = 200 ] && [ "$ap_appcode" = 200 ] || { log "DEVICE_AUTH_POLL_FAILED http=$ap_code"; return 1; }
                    device_message=$(jsonfilter -e '@.message' < "$DIR/device-result.json" 2>/dev/null | tr 'A-Z' 'a-z' || true)
                    case "$device_message" in *cpweb*|*wifidog*) log 'DEVICE_AUTH_BRANCH_UNSUPPORTED'; return 1 ;; esac
                    device_online=$(jsonfilter -e '@.data.online' < "$DIR/device-result.json" 2>/dev/null || true)
                    device_error=$(jsonfilter -e '@.data.error' < "$DIR/device-result.json" 2>/dev/null || true)
                    case "$device_online" in true|1) break ;; esac
                    case "$device_error" in ''|false|0|null|none) ;; *)
                        log 'DEVICE_AUTH_REJECTED'; return 1;
                    esac
                    sleep 1
                    tries=$((tries + 1))
                done
                case "$device_online" in true|1) ;; *) log 'DEVICE_AUTH_TIMEOUT'; return 1 ;; esac
                get_node || { log "WORKFLOW_NODE_FAILED http=$ap_code"; return 1; }
                ;;
            serviceSelection)
                write_session_body "$DIR/services.request" || return 1
                api_post "$ORIGIN/eportal/network/serviceSelection" "$DIR/services.request" services
                [ "$ap_code" = 200 ] && [ "$ap_appcode" = 200 ] || { log "SERVICE_LIST_FAILED http=$ap_code"; return 1; }
                values=$(jsonfilter -e '@.data[*].value' < "$DIR/services.json" 2>/dev/null || true)
                selected=
                count=0
                while IFS= read -r candidate; do
                    [ -n "$candidate" ] || continue
                    count=$((count + 1))
                    if [ -n "$SERVICE" ] && [ "$candidate" = "$SERVICE" ]; then selected=$candidate; fi
                done <<EOF
$values
EOF
                if [ -z "$SERVICE" ] && [ "$count" -eq 1 ]; then
                    selected=$(printf '%s\n' "$values" | sed -n '1p')
                fi
                [ -n "$selected" ] || { log 'SERVICE_SELECTION_AMBIGUOUS'; return 1; }
                case "$selected" in *[!A-Za-z0-9._~-]*) log 'SERVICE_VALUE_UNSAFE'; return 1 ;; esac
                write_session_body "$DIR/service-login.request" service "$selected" || return 1
                api_post "$ORIGIN/eportal/network/serviceLogin" "$DIR/service-login.request" service-login
                [ "$ap_code" = 200 ] && [ "$ap_appcode" = 200 ] || { log "SERVICE_LOGIN_FAILED http=$ap_code"; return 1; }
                service_result=$(jsonfilter -e '@.data.authResult' < "$DIR/service-login.json" 2>/dev/null || true)
                [ "$service_result" = success ] || { log 'SERVICE_LOGIN_REJECTED'; return 1; }
                get_node || { log "WORKFLOW_NODE_FAILED http=$ap_code"; return 1; }
                ;;
            finish|success|completed|loginSuccess)
                workflow_finished=1
                break
                ;;
            authenticate)
                log 'WORKFLOW_STILL_AUTHENTICATE'
                return 1
                ;;
            *)
                log 'WORKFLOW_NODE_UNSUPPORTED'
                return 1
                ;;
        esac
    done
    [ "$workflow_finished" = 1 ] || { log 'WORKFLOW_STEP_LIMIT'; return 1; }

    code204=$(curl -4 --interface "$WAN_IP" -sS --connect-timeout 3 --max-time 8 \
        -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204 2>/dev/null) || code204=000
    https_code=$(curl -4 --interface "$WAN_IP" -sS --connect-timeout 3 --max-time 8 \
        -o "$DIR/https-check.body" -w '%{http_code}' https://www.baidu.com/ 2>/dev/null) || https_code=000
    chmod 600 "$DIR/https-check.body" 2>/dev/null || true
    [ "$https_code" = 200 ] || { log "AUTH_VERIFY_HTTPS_FAILED http=$https_code"; return 1; }
    if [ "$code204" = 204 ]; then
        log 'AUTH_SUCCESS'
        echo 'AUTH_SUCCESS'
        return 0
    fi
    microsoft_code=$(curl -4 --interface "$WAN_IP" -sS --connect-timeout 3 --max-time 8 \
        -o "$DIR/msft-check.body" -w '%{http_code}' https://www.msftconnecttest.com/connecttest.txt 2>/dev/null) || microsoft_code=000
    chmod 600 "$DIR/msft-check.body" 2>/dev/null || true
    if [ "$microsoft_code" = 200 ] && grep -q 'Microsoft Connect Test' "$DIR/msft-check.body"; then
        log 'AUTH_SUCCESS'
        echo 'AUTH_SUCCESS'
        return 0
    fi
    log "AUTH_VERIFY_FAILED http204=$code204 https=$https_code msft=$microsoft_code"
    return 1
}

modern_login
