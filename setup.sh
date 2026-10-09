#!/bin/ash

set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CFG=/etc/config/campus-auth
TMP=/etc/config/.campus-auth.$$

restore_tty() { stty echo </dev/tty 2>/dev/null || true; }
trap restore_tty EXIT HUP INT TERM

if [ "$(id -u)" != 0 ]; then
    echo "Run this setup as root."
    exit 1
fi
[ -t 0 ] || { echo "Run through an interactive SSH terminal."; exit 1; }
[ -x /usr/bin/campus-auth ] || { echo "campus-auth is not installed."; exit 1; }
[ ! -e "$CFG" ] || { echo "Campus Auth config already exists; refusing to overwrite it."; exit 1; }

printf '校园网账号: '
IFS= read -r username </dev/tty
printf '校园网密码: '
stty -echo </dev/tty
IFS= read -r password </dev/tty
stty echo </dev/tty
printf '\n'
[ -n "$username" ] && [ -n "$password" ] || { echo "Account and password must not be empty."; exit 1; }

escape_uci() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

umask 077
{
    printf '%s\n' "config auth 'main'"
    printf ' option username "%s"\n' "$(escape_uci "$username")"
    printf ' option password "%s"\n' "$(escape_uci "$password")"
    printf '%s\n' " option service ''" " option enabled '0'" " option bootstrap_pending '1'"
} > "$TMP"
unset username password
chmod 600 "$TMP"
mv "$TMP" "$CFG"
if ! uci -q get campus-auth.main.bootstrap_pending >/dev/null 2>&1; then
    rm -f "$CFG"
    echo "Could not parse the credentials config; no service was started."
    exit 1
fi

mkdir -p /etc/crontabs
CRON_TMP=/etc/crontabs/.root-campus-auth.$$
if [ -r /etc/crontabs/root ]; then
    grep -v 'CAMPUS_AUTH_BOOTSTRAP' /etc/crontabs/root > "$CRON_TMP" || :
else
    : > "$CRON_TMP"
fi
printf '%s\n' '*/5 * * * * /usr/bin/campus-auth auto >/dev/null 2>&1 # CAMPUS_AUTH_BOOTSTRAP' >> "$CRON_TMP"
chmod 600 "$CRON_TMP"
mv -f "$CRON_TMP" /etc/crontabs/root
/etc/init.d/cron restart >/dev/null 2>&1 || true

echo "Checking router and campus connection..."
/usr/bin/campus-auth check
/usr/bin/campus-auth auto || true
echo "Credentials saved with root-only permissions. The router will retry locally; Codex does not need to remain connected."
