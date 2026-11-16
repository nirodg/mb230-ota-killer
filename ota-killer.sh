#!/bin/sh
# ota-killer.sh - persistent OTA blocker for Vestel/Medion/Horizon MB230
#
# Self-contained, POSIX sh (busybox ash compatible). No external tools beyond
# busybox + the stock /vendor/iptables. Run `install.sh` once; it copies itself
# to /conf/ota-killer, hooks /conf/opentv_payload, and starts a keeper so the
# blocks survive reboots (iptables and bind mounts are volatile).
#
# Commands: install | apply | keeper | status | uninstall
# All operations are idempotent and reversible via uninstall.sh.

set -u

NAME="ota-killer"
INSTALL_DIR="${OTA_KILLER_DIR:-/conf/ota-killer}"
SELF="$INSTALL_DIR/ota-killer.sh"
PAYLOAD="${OTA_KILLER_PAYLOAD:-/conf/opentv_payload}"
HOSTS_FILE="$INSTALL_DIR/hosts"
BLOCKED_FILE="$INSTALL_DIR/blocked.txt"
IP_FILE="$INSTALL_DIR/added-ips.txt"
PID_FILE="$INSTALL_DIR/keeper.pid"
LOG_FILE="$INSTALL_DIR/ota-killer.log"
DENY_FILE="/conf/deniedSoftwareUpdateVersionFile.txt"
OVERRIDE_VERSION="$INSTALL_DIR/deny-version.txt"
INTERVAL="${OTA_KILLER_INTERVAL:-60}"
DNS="${OTA_KILLER_DNS:-8.8.8.8}"
IPTABLES="${OTA_KILLER_IPTABLES:-/vendor/iptables}"
# AWS S3 returns a different IP set on each lookup. Without a cap the keeper
# would add hundreds of rules/day. The hosts override is the real block; the
# firewall is only a backstop, so a bounded list is sufficient.
MAX_IPS="${OTA_KILLER_MAX_IPS:-100}"

HOOK_BEGIN="# --- OTA_KILLER_HOOK_BEGIN ---"
HOOK_END="# --- OTA_KILLER_HOOK_END ---"

# Hostnames used by the firmware's OTA (AWS IoT push, S3 download, Vestel FXM
# fallback hosts). Edit blocked.txt after install to customize.
BLOCKED_DEFAULT="aa8u5ipzaqyfu-ats.iot.eu-west-1.amazonaws.com
s3-eu-west-1.amazonaws.com
vstlupdate.s3-eu-west-1.amazonaws.com
qaupdate.s3-eu-west-1.amazonaws.com
1471772688.fxm6413857471.com
3746622301.fxm6413857471.com
8731299261.fxm6413857471.com
9243217522.fxm6413857471.com"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo t)" "$*" >> "$LOG_FILE" 2>/dev/null; }
say() { printf '%s\n' "$*"; }

blocked_list() {
    if [ -f "$BLOCKED_FILE" ]; then
        cat "$BLOCKED_FILE"
    else
        printf '%s\n' "$BLOCKED_DEFAULT"
    fi
}

# ---------------------------------------------------------------------------
# Layer 1: /etc/hosts override (bind-mounted, read-only /etc stays untouched)
# ---------------------------------------------------------------------------
write_hosts() {
    mkdir -p "$INSTALL_DIR"
    {
        printf '%s\n' '127.0.0.1 localhost'
        blocked_list | while IFS= read -r h; do
            [ -n "$h" ] || continue
            case "$h" in \#*) continue ;; esac
            printf '127.0.0.1 %s\n' "$h"
        done
    } > "$HOSTS_FILE.tmp"
    cat "$HOSTS_FILE.tmp" > "$HOSTS_FILE"
    rm -f "$HOSTS_FILE.tmp"
    chmod 644 "$HOSTS_FILE"
}

mount_hosts() {
    if grep -q ' /etc/hosts ' /proc/mounts 2>/dev/null; then
        return 0
    fi
    if mount --bind "$HOSTS_FILE" /etc/hosts 2>/dev/null; then
        log "mounted $HOSTS_FILE over /etc/hosts"
    else
        log "WARN: could not bind-mount /etc/hosts"
    fi
}

# ---------------------------------------------------------------------------
# Layer 2: iptables REJECT on resolved endpoint IPs (backstop for hardcoded IPs)
# ---------------------------------------------------------------------------
resolve_ips() {
    # Query external DNS directly so our own hosts override cannot skew results.
    nslookup "$1" "$DNS" 2>/dev/null | awk '/^Name:/{f=1;next} f && /^Address/{print $NF}'
}

firewall_apply() {
    [ -x "$IPTABLES" ] || IPTABLES="$(command -v iptables 2>/dev/null || true)"
    [ -n "$IPTABLES" ] || { log "WARN: no iptables binary"; return 0; }
    touch "$IP_FILE"
    count="$(wc -l < "$IP_FILE" 2>/dev/null || echo 0)"
    if [ "$count" -ge "$MAX_IPS" ]; then
        log "firewall IP cap reached ($count/$MAX_IPS); hosts override still active"
        return 0
    fi
    blocked_list | while IFS= read -r h; do
        [ -n "$h" ] || continue
        case "$h" in \#*) continue ;; esac
        for ip in $(resolve_ips "$h"); do
            case "$ip" in
                127.*|0.0.0.0|''|*[!0-9.]*) continue ;;
            esac
            grep -qxF "$ip" "$IP_FILE" 2>/dev/null && continue
            if "$IPTABLES" -A OUTPUT -d "$ip" -j REJECT 2>/dev/null; then
                printf '%s\n' "$ip" >> "$IP_FILE"
                log "iptables REJECT $ip ($h)"
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Layer 3: deny the pending firmware version using the firmware's own file
# ---------------------------------------------------------------------------
deny_apply() {
    pending=""
    if [ -f "$OVERRIDE_VERSION" ]; then
        pending="$(cat "$OVERRIDE_VERSION" 2>/dev/null | tr -d '\r\n ')"
    fi
    if [ -z "$pending" ] && [ -f /conf/ftpUpdateVersionFile.txt ]; then
        # format: <current>,<available> - e.g. V.0.51.19.0,V.0.51.52.5
        pending="$(cut -d, -f2 /conf/ftpUpdateVersionFile.txt 2>/dev/null | tr -d '\r\n ')"
    fi
    [ -n "$pending" ] || return 0
    if [ ! -f "$DENY_FILE" ] || [ "$(cat "$DENY_FILE" 2>/dev/null | tr -d '\r\n ')" != "$pending" ]; then
        printf '%s\n' "$pending" > "$DENY_FILE"
        chmod 644 "$DENY_FILE" 2>/dev/null || true
        log "denied firmware version: $pending"
    fi
}

apply_all() {
    write_hosts
    mount_hosts
    firewall_apply
    deny_apply
}

# ---------------------------------------------------------------------------
# Persistence hook in /conf/opentv_payload (inserted after line 1, before exec)
# ---------------------------------------------------------------------------
hook_add() {
    [ -f "$PAYLOAD" ] || { log "WARN: payload $PAYLOAD not found"; return 1; }
    grep -qF '#!/bin/sh' "$PAYLOAD" 2>/dev/null || {
        log "WARN: payload is not a text shell script; not modifying it"
        return 1
    }
    if grep -qF "$HOOK_BEGIN" "$PAYLOAD" 2>/dev/null; then
        log "hook already present in $PAYLOAD"
        return 0
    fi
    cp "$PAYLOAD" "$PAYLOAD.bak.otakiller" 2>/dev/null || true
    {
        head -n 1 "$PAYLOAD"
        printf '\n%s\n' "$HOOK_BEGIN"
        printf '[ -x "%s" ] && sh "%s" keeper >/dev/null 2>&1 &\n' "$SELF" "$SELF"
        printf '%s\n\n' "$HOOK_END"
        tail -n +2 "$PAYLOAD"
    } > "$PAYLOAD.tmp" && cat "$PAYLOAD.tmp" > "$PAYLOAD" && rm -f "$PAYLOAD.tmp"
    chmod 755 "$PAYLOAD" 2>/dev/null || true
    log "hook added to $PAYLOAD"
}

hook_remove() {
    [ -f "$PAYLOAD" ] || return 0
    awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }
    ' "$PAYLOAD" > "$PAYLOAD.tmp" && cat "$PAYLOAD.tmp" > "$PAYLOAD" && rm -f "$PAYLOAD.tmp"
    chmod 755 "$PAYLOAD" 2>/dev/null || true
    log "hook removed from $PAYLOAD"
}

keeper_running() {
    [ -f "$PID_FILE" ] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

keeper_start() {
    if keeper_running; then
        log "keeper already running (pid $(cat "$PID_FILE"))"
        return 0
    fi
    sh "$SELF" keeper >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$PID_FILE"
    log "keeper started (pid $!)"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_install() {
    mkdir -p "$INSTALL_DIR"
    if [ "$0" != "$SELF" ]; then
        cp "$0" "$SELF"
        chmod 755 "$SELF"
    fi
    if [ ! -f "$BLOCKED_FILE" ]; then
        printf '%s\n' "$BLOCKED_DEFAULT" > "$BLOCKED_FILE"
    fi
    write_hosts
    apply_all
    hook_add
    keeper_start
    say "$NAME installed to $INSTALL_DIR"
    say "  hosts override : $(grep -c ' /etc/hosts ' /proc/mounts 2>/dev/null) mount(s)"
    say "  rejected IPs   : $(wc -l < "$IP_FILE" 2>/dev/null)"
    say "  denied version : $(cat "$DENY_FILE" 2>/dev/null)"
    say "  run '$SELF status' to verify"
}

cmd_apply() { apply_all; }

cmd_keeper() {
    log "keeper loop started"
    while :; do
        apply_all
        sleep "$INTERVAL"
    done
}

cmd_status() {
    say "=== $NAME status ==="
    say "install dir : $INSTALL_DIR"
    if grep -q ' /etc/hosts ' /proc/mounts 2>/dev/null; then
        say "hosts mount : ACTIVE ($(grep ' /etc/hosts ' /proc/mounts | head -1))"
    else
        say "hosts mount : INACTIVE"
    fi
    say "blocked hosts: $(blocked_list | grep -c . )"
    if [ -f "$IP_FILE" ]; then
        say "rejected IPs : $(wc -l < "$IP_FILE")"
    else
        say "rejected IPs : 0"
    fi
    if [ -f "$IPTABLES" ]; then
        "$IPTABLES" -L OUTPUT -n 2>/dev/null | grep -i reject | sed 's/^/  iptables: /'
    fi
    if [ -f "$DENY_FILE" ]; then
        say "deny version : $(cat "$DENY_FILE")"
    else
        say "deny version : NOT SET"
    fi
    if grep -qF "$HOOK_BEGIN" "$PAYLOAD" 2>/dev/null; then
        say "payload hook : ACTIVE"
    else
        say "payload hook : INACTIVE"
    fi
    if keeper_running; then
        say "keeper       : RUNNING (pid $(cat "$PID_FILE"))"
    else
        say "keeper       : STOPPED"
    fi
}

cmd_uninstall() {
    hook_remove
    if keeper_running; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    if grep -q ' /etc/hosts ' /proc/mounts 2>/dev/null; then
        umount /etc/hosts 2>/dev/null || log "WARN: could not unmount /etc/hosts"
    fi
    if [ -f "$IP_FILE" ] && [ -x "$IPTABLES" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            "$IPTABLES" -D OUTPUT -d "$ip" -j REJECT 2>/dev/null || true
        done < "$IP_FILE"
    fi
    rm -f "$DENY_FILE"
    rm -rf "$INSTALL_DIR"
    say "$NAME uninstalled (payload backup kept at $PAYLOAD.bak.otakiller)"
}

case "${1:-install}" in
    install)   cmd_install ;;
    apply)     cmd_apply ;;
    keeper)    cmd_keeper ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    *) say "usage: $0 {install|apply|keeper|status|uninstall}"; exit 2 ;;
esac
