#!/bin/bash

# Created by: @COD-DEXTER
# Enterprise-grade refactored version 3.1

(set -o pipefail) 2>/dev/null && set -o pipefail
set +e

# ==========================================
# Section 1: Configuration & Global Variables
# ==========================================
VERSION="3.1"
CONFIG_FILE="/etc/dexter-warp.conf"
SCRIPT_PATH="/usr/local/bin/dexter-warp"
WIREPROXY_BIN="/usr/local/bin/wireproxy"
WIREPROXY_CONF="/etc/wireproxy.conf"
CF_API="https://api.cloudflareclient.com/v0a2158"
LOG_PATH="/var/log/dexter-warp.log"
PID_FILE="/run/dexter-warp.pid"
LOCK_FILE="/run/dexter-warp.lock"
CACHE_DIR="/var/cache/dexter-warp"
CACHE_FILE="${CACHE_DIR}/ip"

DEFAULT_SOCKS5_PORT="10808"
DEFAULT_PROXY_IP="127.0.0.1"
# Conservative MTU for the WireGuard interface. WireGuard adds ~60-80 bytes
# of overhead per packet; inside nested Docker/VPS environments the
# effective path MTU is often lower than the host's 1500, which causes the
# handshake to succeed (small UDP packets) while all real data traffic
# silently blackholes (large packets get dropped, no ICMP frag-needed
# makes it back). 1280 is the IPv6 minimum-safe MTU and avoids this almost
# everywhere at the cost of slightly more packet overhead.
DEFAULT_WG_MTU="1280"

SOCKS5_PORT="$DEFAULT_SOCKS5_PORT"
PROXY_IP="$DEFAULT_PROXY_IP"
IP_VERSION="4"
RUN_MODE="VPS"
CURRENT_MODE="$RUN_MODE"

WG_PRIV_KEY=""
WG_PEER_PUB_KEY=""
WG_PEER_ENDPOINT=""
WG_IPV4=""
WG_IPV6=""
WG_REG_ID=""
WG_REG_TOKEN=""
WG_MTU=""

# Cyberpunk Neon Rebranded Color Scheme
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[0;36m'
NC='\033[0m'

LAST_IP_CHECK=0
CACHED_IP=""
CACHED_COUNTRY=""
IP_CACHE_TTL=300

SELF_HEAL_BACKOFF=0
SELF_HEAL_MAX_BACKOFF=120
SELF_HEAL_COOLDOWN=0
SELF_HEAL_MAX_RETRIES=3
SELF_HEAL_RETRY_COUNT=0
SELF_HEAL_CONSECUTIVE_FAIL=0
SELF_HEAL_MAX_CONSECUTIVE=5

LOG_VERBOSITY="INFO"
LOG_MAX_SIZE=5242880
LOG_MAX_FILES=3
SPIN_PID=""
PATHS_INITIALIZED=false
TEMP_DIRS=()

IS_ALPINE=false

declare -A T
T[root_check]="Checking root access privileges..."
T[root_ok]="Root access privileges confirmed."
T[root_fail]="This script must be executed as root."
T[os_check]="Verifying OS compatibility..."
T[os_ok]="OS compatibility verified successfully."
T[os_fail]="Your OS is not supported. Supported: Debian, Ubuntu, Alpine."
T[dep_check]="Installing essential system dependencies..."
T[dep_ok]="Required packages installed successfully."
T[dep_fail]="Dependency installation failed."
T[wp_dl]="Downloading WireProxy binary..."
T[wp_ok]="WireProxy installed successfully."
T[wp_fail]="WireProxy installation failed."
T[reg_cf]="Registering account with Cloudflare WARP..."
T[reg_ok]="Registration with Cloudflare API succeeded."
T[reg_fail]="WARP registration failed."
T[launch]="Launching WARP service..."
T[launch_ok]="WARP service started."
T[launch_fail]="Failed to start WARP service."
T[verify_con]="Verifying SOCKS5 active traffic..."
T[verify_ok]="SOCKS5 proxy traffic verified successfully."
T[verify_fail]="SOCKS5 proxy traffic verification failed."

# ==========================================
# Section 2: Environment Detection
# ==========================================
detect_environment() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Minimal"
        return 0
    fi
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${container:-}" ] 2>/dev/null; then
        echo "Container"
        return 0
    fi
    if [ -f /proc/1/cgroup ] 2>/dev/null; then
        if grep -q -E "docker|containerd|sandbox|kubepods|lxc" /proc/1/cgroup /proc/self/cgroup 2>/dev/null; then
            echo "Container"
            return 0
        fi
    fi
    if [ -f /proc/1/environ ] 2>/dev/null; then
        if grep -q "KUBERNETES_SERVICE_HOST" /proc/1/environ 2>/dev/null; then
            echo "Container"
            return 0
        fi
    fi
    if [ -n "${RAILWAY_STATIC_URL:-}" ] || [ -n "${RENDER:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ]; then
        echo "Container"
        return 0
    fi
    if [ -f /.lxc-env ] 2>/dev/null || [ -n "${LXC_ROOTFS_MOUNT:-}" ]; then
        echo "Container"
        return 0
    fi
    if [ -f /proc/1/sched ] 2>/dev/null; then
        local init_name
        init_name=$(head -n1 /proc/1/sched 2>/dev/null)
        if [[ "$init_name" == *"(systemd)"* ]] || [[ "$init_name" == *"(init)"* ]] || [[ "$init_name" == *"(sbin/init)"* ]]; then
            echo "VPS"
            return 0
        fi
    fi
    echo "VPS"
}

detect_os() {
    if [ -f /etc/alpine-release ]; then
        IS_ALPINE=true
        return 0
    fi
    if [ -f /etc/os-release ]; then
        local id="" id_like=""
        id=$(awk -F= '$1=="ID" {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
        id_like=$(awk -F= '$1=="ID_LIKE" {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
        case "$id" in
            alpine)
                IS_ALPINE=true ;;
            ubuntu|debian|centos|rhel|fedora|arch|alpine)
                IS_ALPINE=false ;;
            *)
                if [[ "$id_like" == *alpine* ]]; then
                    IS_ALPINE=true
                else
                    IS_ALPINE=false
                fi ;;
        esac
    fi
}

is_minimal() {
    [[ "$RUN_MODE" == "Minimal" || "$RUN_MODE" == "MODE_MINIMAL" ]]
}

_reset_self_heal_state() {
    SELF_HEAL_BACKOFF=0
    SELF_HEAL_COOLDOWN=0
    SELF_HEAL_RETRY_COUNT=0
    SELF_HEAL_CONSECUTIVE_FAIL=0
}

_ensure_dirs() {
    local _ed_dir
    for _ed_dir in "$(dirname "$CONFIG_FILE")" "$(dirname "$WIREPROXY_CONF")" "$(dirname "$WIREPROXY_BIN")" "$(dirname "$LOG_PATH")" "$(dirname "$CACHE_FILE")" "$(dirname "$PID_FILE")" "$(dirname "$LOCK_FILE")"; do
        [ -n "$_ed_dir" ] && mkdir -p "$_ed_dir" 2>/dev/null || true
    done
}

# ========== POSIX / BusyBox Safe Randomizer ==========
get_random() {
    if [ -n "${RANDOM:-}" ] 2>/dev/null; then
        echo "$RANDOM"
    else
        local seed
        seed=$(date +%s%N 2>/dev/null || date +%s 2>/dev/null || echo 1)
        echo "$(( (seed + $$) % 32768 ))"
    fi
}

# ==========================================
# Section 3: Path Manager
# ==========================================
init_paths() {
    if [ "$CURRENT_MODE" = "VPS" ] && [ "$(id -u)" -eq 0 ] && [ -w "/etc" ] 2>/dev/null; then
        CONFIG_FILE="/etc/dexter-warp.conf"
        SCRIPT_PATH="/usr/local/bin/dexter-warp"
        WIREPROXY_BIN="/usr/local/bin/wireproxy"
        WIREPROXY_CONF="/etc/wireproxy.conf"
        if [ -d /run ] && [ -w /run ] 2>/dev/null; then
            PID_FILE="/run/dexter-warp.pid"
            LOCK_FILE="/run/dexter-warp.lock"
        elif [ -d /var/run ] && [ -w /var/run ] 2>/dev/null; then
            PID_FILE="/var/run/dexter-warp.pid"
            LOCK_FILE="/var/run/dexter-warp.lock"
        else
            PID_FILE="/tmp/dexter-warp.pid"
            LOCK_FILE="/tmp/dexter-warp.lock"
        fi
        if [ -d /var/log ] && [ -w /var/log ] 2>/dev/null; then
            LOG_PATH="/var/log/dexter-warp.log"
        else
            LOG_PATH="/tmp/dexter-warp.log"
        fi
        CACHE_DIR="/var/cache/dexter-warp"
        if mkdir -p "$CACHE_DIR" 2>/dev/null && [ -w "$CACHE_DIR" ]; then
            CACHE_FILE="${CACHE_DIR}/ip"
        else
            CACHE_DIR="/tmp"
            CACHE_FILE="/tmp/.dexter_cache"
        fi
    else
        local runtime_dir="${XDG_RUNTIME_DIR:-}"
        { [ -z "$runtime_dir" ] || [ ! -w "$runtime_dir" ] 2>/dev/null; } && runtime_dir="/tmp"
        local home_dir="${HOME:-/tmp}"
        [ ! -w "$home_dir" ] 2>/dev/null && home_dir="/tmp"

        CONFIG_FILE="${home_dir}/.dexter-warp.conf"
        SCRIPT_PATH="${home_dir}/.local/bin/dexter-warp"
        WIREPROXY_BIN="${home_dir}/.local/bin/wireproxy"
        WIREPROXY_CONF="${home_dir}/.local/wireproxy.conf"
        PID_FILE="${runtime_dir}/dexter-warp.pid"
        LOCK_FILE="${runtime_dir}/dexter-warp.lock"
        LOG_PATH="${runtime_dir}/dexter-warp.log"
        CACHE_DIR="$runtime_dir"
        CACHE_FILE="${runtime_dir}/.dexter_cache"
        mkdir -p "${home_dir}/.local/bin" 2>/dev/null || true
        mkdir -p "${home_dir}/.local" 2>/dev/null || true
        mkdir -p "${home_dir}" 2>/dev/null || true
    fi
    PATHS_INITIALIZED=true
}

get_config_path() { echo "$CONFIG_FILE"; }
get_wireproxy_conf_path() { echo "$WIREPROXY_CONF"; }
get_wireproxy_bin_path() { echo "$WIREPROXY_BIN"; }
get_pid_path() { echo "$PID_FILE"; }
get_lock_path() { echo "$LOCK_FILE"; }
get_log_path() { echo "$LOG_PATH"; }
get_cache_path() { echo "$CACHE_FILE"; }

# ==========================================
# Section 4: Config System & Parser (POSIX & BusyBox Safe)
# ==========================================
validate_ipv4() {
    local ip="$1"
    case "$ip" in
        *[!0-9.]*) return 1 ;;
    esac
    local o1 o2 o3 o4
    o1=$(echo "$ip" | cut -d. -f1)
    o2=$(echo "$ip" | cut -d. -f2)
    o3=$(echo "$ip" | cut -d. -f3)
    o4=$(echo "$ip" | cut -d. -f4)
    [ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ] && [ -n "$o4" ] || return 1
    [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ] 2>/dev/null
}

validate_ipv6() {
    case "$1" in
        *[!0-9a-fA-F:]*) return 1 ;;
    esac
    [[ "$1" == *:* ]]
}

validate_ip() {
    validate_ipv4 "$1" && return 0
    validate_ipv6 "$1" && return 0
    return 1
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

validate_endpoint() {
    local ep="$1"
    local host="${ep%%:*}"
    local port="${ep##*:}"
    # Accept bare IPv4/IPv6 (hex/dot/colon chars) AND hostnames (letters,
    # digits, dots, hyphens) - the old regex only matched IP-like strings,
    # so the one hostname entry in WARP_ENDPOINTS (engage.cloudflareclient.com)
    # always failed validation and was silently skipped in every rotation.
    if [[ "$host" =~ ^[0-9a-fA-F.:]+$ || "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
       && [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        echo "$ep"
    else
        echo ""
    fi
}

parse_config_val() {
    local key="$1"
    local default_val="$2"
    local conf_file
    conf_file=$(get_config_path)
    [ ! -f "$conf_file" ] && { echo "$default_val"; return; }

    local line
    line=$(grep -m1 -F "${key}=" "$conf_file" 2>/dev/null)
    [ -z "$line" ] && { echo "$default_val"; return; }

    local val="${line#*=}"
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"
    val="${val%%$'\n'}"
    val="${val%%$'\r'}"

    case "$key" in
        SOCKS5_PORT)
            if validate_port "$val"; then
                echo "$val"
            else
                echo "$default_val"
            fi
            ;;
        PROXY_IP)
            if validate_ip "$val"; then
                echo "$val"
            else
                echo "$default_val"
            fi
            ;;
        IP_VERSION)
            case "$val" in
                4|dual|6) echo "$val" ;;
                *) echo "$default_val" ;;
            esac
            ;;
        WG_PRIV_KEY)
            [[ "$val" =~ ^[A-Za-z0-9+/=]+$ ]] && [ "${#val}" -ge 40 ] && echo "$val" || echo "$default_val"
            ;;
        WG_PEER_PUB_KEY)
            [[ "$val" =~ ^[A-Za-z0-9+/=]+$ ]] && [ "${#val}" -ge 40 ] && echo "$val" || echo "$default_val"
            ;;
        WG_REG_ID)
            [[ "$val" =~ ^[a-f0-9-]+$ ]] && [ "${#val}" -ge 10 ] && echo "$val" || echo "$default_val"
            ;;
        WG_REG_TOKEN)
            [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]] && [ "${#val}" -ge 10 ] && echo "$val" || echo "$default_val"
            ;;
        WG_IPV4)
            validate_ipv4 "$val" && echo "$val" || echo "$default_val"
            ;;
        WG_IPV6)
            validate_ipv6 "$val" && echo "$val" || echo "$default_val"
            ;;
        RUN_MODE)
            case "$val" in
                VPS|Container|Minimal|MODE_MINIMAL) echo "$val" ;;
                *) echo "$default_val" ;;
            esac
            ;;
        *)
            echo "$val"
            ;;
    esac
}

save_config() {
    local conf_file
    conf_file=$(get_config_path)
    mkdir -p "$(dirname "$conf_file")" 2>/dev/null || true
    local tmp_conf="${conf_file}.tmp.$$"
    printf '%s\n' \
        "SOCKS5_PORT=$SOCKS5_PORT" \
        "PROXY_IP=\"$PROXY_IP\"" \
        "WIREPROXY_CONF=\"$WIREPROXY_CONF\"" \
        "SCRIPT_PATH=\"$SCRIPT_PATH\"" \
        "WIREPROXY_BIN=\"$WIREPROXY_BIN\"" \
        "VERSION=\"$VERSION\"" \
        "IP_VERSION=\"$IP_VERSION\"" \
        "RUN_MODE=\"$RUN_MODE\"" \
        "WG_IPV4=\"$WG_IPV4\"" \
        "WG_IPV6=\"$WG_IPV6\"" \
        "WG_PRIV_KEY=\"$WG_PRIV_KEY\"" \
        "WG_PEER_PUB_KEY=\"$WG_PEER_PUB_KEY\"" \
        "WG_PEER_ENDPOINT=\"$WG_PEER_ENDPOINT\"" \
        "WG_REG_ID=\"$WG_REG_ID\"" \
        "WG_REG_TOKEN=\"$WG_REG_TOKEN\"" > "$tmp_conf"
    if mv -f "$tmp_conf" "$conf_file" 2>/dev/null; then
        chmod 600 "$conf_file" 2>/dev/null || true
        log_msg "INFO" "Configuration saved"
    else
        rm -f "$tmp_conf" 2>/dev/null
        log_msg "ERROR" "Configuration save failed"
    fi
}

load_config() {
    local conf_file
    conf_file=$(get_config_path)
    [ ! -f "$conf_file" ] && return

    SOCKS5_PORT=$(parse_config_val "SOCKS5_PORT" "$DEFAULT_SOCKS5_PORT")
    PROXY_IP=$(parse_config_val "PROXY_IP" "$DEFAULT_PROXY_IP")
    IP_VERSION=$(parse_config_val "IP_VERSION" "4")
    WG_IPV4=$(parse_config_val "WG_IPV4" "")
    WG_IPV6=$(parse_config_val "WG_IPV6" "")
    WG_PRIV_KEY=$(parse_config_val "WG_PRIV_KEY" "")
    WG_PEER_PUB_KEY=$(parse_config_val "WG_PEER_PUB_KEY" "")
    WG_PEER_ENDPOINT=$(parse_config_val "WG_PEER_ENDPOINT" "")
    WG_REG_ID=$(parse_config_val "WG_REG_ID" "")
    WG_REG_TOKEN=$(parse_config_val "WG_REG_TOKEN" "")

    if [ -n "$WG_PEER_ENDPOINT" ]; then
        local safe_ep
        safe_ep=$(validate_endpoint "$WG_PEER_ENDPOINT")
        if [ -n "$safe_ep" ]; then
            WG_PEER_ENDPOINT="$safe_ep"
        fi
    fi

    local saved_mode
    saved_mode=$(parse_config_val "RUN_MODE" "")
    if [ -n "$saved_mode" ]; then
        RUN_MODE="$saved_mode"
        CURRENT_MODE="$RUN_MODE"
    fi
}

# ==========================================
# Section 5: Lock System
# ==========================================
acquire_lock() {
    local lock_file
    lock_file=$(get_lock_path)
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

    local lock_dir="${lock_file}.dir"

    if command -v flock &>/dev/null; then
        exec 200>"$lock_file"
        if flock -n 200 2>/dev/null; then
            printf '%s\n' "$$" > "${lock_file}.pid" 2>/dev/null || true
            return 0
        fi
        exec 200>&- 2>/dev/null || true
        local flock_pid=""
        [ -f "${lock_file}.pid" ] && read -r flock_pid < "${lock_file}.pid" 2>/dev/null || flock_pid=""
        if [[ "$flock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$flock_pid" 2>/dev/null; then
            rm -f "$lock_file" "${lock_file}.pid" 2>/dev/null || true
            exec 200>"$lock_file"
            if flock -n 200 2>/dev/null; then
                printf '%s\n' "$$" > "${lock_file}.pid" 2>/dev/null || true
                return 0
            fi
            exec 200>&- 2>/dev/null || true
        fi
        return 1
    fi

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "${lock_dir}/pid" 2>/dev/null || true
        return 0
    fi

    if [ -f "${lock_dir}/pid" ]; then
        local old_pid=""
        read -r old_pid < "${lock_dir}/pid" 2>/dev/null || old_pid=""
        if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
            if ! kill -0 "$old_pid" 2>/dev/null; then
                rm -rf "$lock_dir" 2>/dev/null || true
                if mkdir "$lock_dir" 2>/dev/null; then
                    printf '%s\n' "$$" > "${lock_dir}/pid" 2>/dev/null || true
                    return 0
                fi
            fi
        fi
    fi
    return 1
}

safe_cleanup() {
    exec 200>&- 2>/dev/null || true
    if command -v tput &>/dev/null; then
        tput cnorm 2>/dev/null || true
        tput sgr0 2>/dev/null || true
    fi
    printf "\r\033[K\n" 2>/dev/null || printf "\n" 2>/dev/null || true
    if [ -n "${SPIN_PID:-}" ]; then
        kill "$SPIN_PID" 2>/dev/null
        wait "$SPIN_PID" 2>/dev/null || true
        SPIN_PID=""
    fi
    # IMPORTANT: do NOT blindly "pkill -P $$" here. wireproxy is launched
    # via "nohup ... &" in _service_start, which only makes it immune to
    # SIGHUP -- it is still a direct child of this script's PID. A blanket
    # pkill -P "$$" on every exit path (including normal menu exit via
    # option 0, Ctrl+C, and SSH disconnect delivering SIGHUP) was killing
    # the running wireproxy/WARP tunnel every single time the menu closed,
    # which is why the connection never survived leaving the script. We
    # still want to reap any *other* stray child processes (e.g. a spinner
    # or curl call that didn't get cleaned up), so kill children
    # individually while explicitly skipping the tracked wireproxy PID.
    local _cl_wpid=""
    if [ -n "${PID_FILE:-}" ] && [ -f "$PID_FILE" ]; then
        read -r _cl_wpid < "$PID_FILE" 2>/dev/null || _cl_wpid=""
    fi
    local _cl_child
    for _cl_child in $(pgrep -P "$$" 2>/dev/null); do
        [ -n "$_cl_wpid" ] && [ "$_cl_child" = "$_cl_wpid" ] && continue
        kill "$_cl_child" 2>/dev/null || true
    done
    local _cl_lock
    _cl_lock=$(get_lock_path)
    rm -f "$_cl_lock" "${_cl_lock}.pid" 2>/dev/null || true
    rm -rf "${_cl_lock}.dir" 2>/dev/null || true
    if [ "${#TEMP_DIRS[@]:-0}" -gt 0 ] 2>/dev/null; then
        local _cl_entry
        for _cl_entry in "${TEMP_DIRS[@]}"; do
            rm -rf "$_cl_entry" 2>/dev/null || true
        done
    fi
}
trap safe_cleanup EXIT
# NOTE: trapping INT/TERM/HUP with just "safe_cleanup" (no exit) replaces
# the shell's default disposition for these signals, which is to
# terminate the process. Without an explicit exit after cleanup, the
# script would just run safe_cleanup and then KEEP RUNNING -- e.g. an SSH
# disconnect (SIGHUP) would leave an orphaned, terminal-less copy of this
# script alive in the background forever, still holding the flock lock fd
# open. That orphan is real and alive (not a stale/dead PID), so the
# stale-lock auto-recovery in acquire_lock correctly refuses to clear it,
# and every future launch fails with "Another instance is already
# running" pointing at that immortal orphan's PID until something else
# happens to kill it. Explicitly exiting with the conventional
# 128+signal code after cleanup ensures the process actually terminates,
# which releases the lock fd immediately and lets the next launch proceed
# normally.
trap 'safe_cleanup; exit 130' INT
trap 'safe_cleanup; exit 143' TERM
trap 'safe_cleanup; exit 129' HUP

# ==========================================
# Section 6: Logger
# ==========================================
log_msg() {
    local level="$1"
    shift

    case "$level" in
        DEBUG) [ "$LOG_VERBOSITY" != "DEBUG" ] && return 0 ;;
        INFO)  [[ "$LOG_VERBOSITY" == "ERROR" ]] && return 0 ;;
        WARNING) [[ "$LOG_VERBOSITY" == "ERROR" ]] && return 0 ;;
        ERROR) ;;
    esac

    local log_file
    log_file=$(get_log_path)
    [ -z "$log_file" ] && return 0
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

    if [ -f "$log_file" ]; then
        local fsize=0
        if command -v stat &>/dev/null; then
            fsize=$(stat -c%s "$log_file" 2>/dev/null || stat -f%z "$log_file" 2>/dev/null || echo 0)
        else
            fsize=$(wc -c < "$log_file" 2>/dev/null || echo 0)
        fi
        if [ "$fsize" -gt "$LOG_MAX_SIZE" ] 2>/dev/null; then
            local i
            for ((i = LOG_MAX_FILES; i >= 2; i--)); do
                local prev=$((i - 1))
                [ -f "${log_file}.${prev}" ] && mv "${log_file}.${prev}" "${log_file}.${i}" 2>/dev/null || true
            done
            mv "$log_file" "${log_file}.1" 2>/dev/null || true
        fi
    fi

    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$log_file" 2>/dev/null || true
}

# ==========================================
# Section 7: Network Diagnostics
# ==========================================
check_internet() {
    local stderr_file exit_code
    stderr_file=$(mktemp 2>/dev/null) || stderr_file="/tmp/.dexter_inet_err.$$"
    curl -s --connect-timeout 3 --max-time 5 --fail https://1.1.1.1 >/dev/null 2>"$stderr_file"
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        local curl_err
        curl_err=$(tr -s '\n' ' ' < "$stderr_file" 2>/dev/null)
        log_msg "ERROR" "check_internet failed | curl_exit=${exit_code} ($(curl_exit_meaning "$exit_code")) | curl_stderr=\"${curl_err}\""
    fi
    rm -f "$stderr_file" 2>/dev/null
    return "$exit_code"
}

check_dns_resolution() {
    local host="${1:-1.1.1.1}"
    if command -v host &>/dev/null; then
        host "$host" >/dev/null 2>&1
    elif command -v nslookup &>/dev/null; then
        nslookup "$host" >/dev/null 2>&1
    else
        getent hosts "$host" >/dev/null 2>&1
    fi
}

check_connectivity_full() {
    if ! check_internet; then
        if ! check_dns_resolution "1.1.1.1"; then
            echo "dns_failure"
        elif ! check_dns_resolution "google.com"; then
            echo "routing_failure"
        else
            echo "no_internet"
        fi
        return
    fi
    echo "ok"
}

check_ipv6_available() {
    local has_iface=false
    if [ -f /proc/net/if_inet6 ] 2>/dev/null; then
        local iface
        while IFS= read -r iface; do
            local iface_name="${iface%% *}"
            [ "$iface_name" = "lo" ] && continue
            local path="/proc/sys/net/ipv6/conf/${iface_name}/disable_ipv6"
            if [ -f "$path" ] 2>/dev/null; then
                local disabled
                read -r disabled < "$path" 2>/dev/null || disabled="1"
                [ "$disabled" = "0" ] && has_iface=true && break
            fi
        done < /proc/net/if_inet6
    fi
    if [ "$has_iface" = false ]; then
        ip -6 route show default >/dev/null 2>&1 && has_iface=true
    fi
    [ "$has_iface" = false ] && return 1

    # Having a local IPv6 interface/route (e.g. a container's own
    # link-local or NAT-internal IPv6 address) does NOT mean outbound
    # IPv6 actually reaches the internet - very common in Docker setups
    # where the host has no real IPv6 uplink. Confirm with a real,
    # short-timeout connectivity probe before calling it "available",
    # otherwise the menu advertises a mode that will just hang/fail.
    curl -6 -s --connect-timeout 3 --max-time 5 -o /dev/null \
        "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null && return 0

    return 1
}

check_mtu() {
    local target="${1:-1.1.1.1}"
    local proxy_args=""
    [ -n "${2:-}" ] && proxy_args="--socks5 $2"
    if ping -c 1 -M do -s 1400 "$target" >/dev/null 2>&1; then
        echo "ok"
    elif ping -c 1 -M do -s 1280 "$target" >/dev/null 2>&1; then
        echo "reduced"
    else
        echo "broken"
    fi
}

classify_network_error() {
    local error_output="$1"
    if [[ "$error_output" == *"Connection refused"* ]]; then
        echo "connection_refused"
    elif [[ "$error_output" == *"timed out"* ]] || [[ "$error_output" == *"Timeout"* ]]; then
        echo "timeout"
    elif [[ "$error_output" == *"Could not resolve host"* ]]; then
        echo "dns_resolution"
    elif [[ "$error_output" == *"Network is unreachable"* ]]; then
        echo "network_unreachable"
    elif [[ "$error_output" == *"Connection reset"* ]]; then
        echo "connection_reset"
    else
        echo "unknown"
    fi
}

# ==========================================
# Section 8: HTTP Wrappers
# ==========================================
http_get() {
    local url="$1"
    shift
    local stderr_file out exit_code http_code body marker
    marker="HTTPCODE_MARKER_"
    stderr_file=$(mktemp 2>/dev/null) || stderr_file="/tmp/.dexter_http_err.$$"

    out=$(curl -s --fail --retry "${HTTP_RETRY:-2}" \
        --connect-timeout "${HTTP_CONNECT_TIMEOUT:-3}" --max-time "${HTTP_MAX_TIME:-5}" \
        -w "${marker}%{http_code}" "$@" "$url" 2>"$stderr_file")
    exit_code=$?

    http_code="${out##*${marker}}"
    body="${out%${marker}*}"

    if [ "$exit_code" -ne 0 ]; then
        local curl_err
        curl_err=$(tr -s '\n' ' ' < "$stderr_file" 2>/dev/null)
        log_msg "ERROR" "http_get failed | url=${url} | curl_exit=${exit_code} ($(curl_exit_meaning "$exit_code")) | http_code=${http_code:-N/A} | curl_stderr=\"${curl_err}\" | body=\"${body:-EMPTY}\""
    fi

    rm -f "$stderr_file" 2>/dev/null
    printf '%s' "$body"
    return "$exit_code"
}

# Human readable meaning for common curl exit codes, used for diagnostics in logs.
curl_exit_meaning() {
    case "$1" in
        0) echo "success" ;;
        6) echo "could not resolve host (DNS failure / domain blocked)" ;;
        7) echo "could not connect to host (refused / filtered / port blocked)" ;;
        22) echo "HTTP error response (4xx/5xx) returned by server" ;;
        28) echo "operation timed out (connect-timeout/max-time exceeded, likely filtered)" ;;
        35) echo "SSL/TLS handshake failed (possible SNI/TLS filtering)" ;;
        52) echo "empty reply from server (connection reset mid-request)" ;;
        56) echo "failure receiving network data (connection reset/blocked)" ;;
        *) echo "see curl(1) exit codes" ;;
    esac
}

http_download() {
    local url="$1"
    shift
    curl -L --fail --retry 2 --connect-timeout 10 --max-time 120 "$@" "$url" 2>/dev/null
}

version_gt() {
    [ "$1" = "$2" ] && return 1
    if command -v sort &>/dev/null && printf '1\n2' | sort -V &>/dev/null 2>&1; then
        printf '%s\n%s' "$2" "$1" | sort -V -C 2>/dev/null
    else
        local v1_major v1_minor v2_major v2_minor
        v1_major="${1%%.*}"
        v1_minor="${1#*.}"
        v1_minor="${v1_minor%%.*}"
        v2_major="${2%%.*}"
        v2_minor="${2#*.}"
        v2_minor="${v2_minor%%.*}"
        v1_minor="${v1_minor:-0}"
        v2_minor="${v2_minor:-0}"
        if [ "$v1_major" -gt "$v2_major" ] 2>/dev/null; then
            return 0
        elif [ "$v1_major" -eq "$v2_major" ] 2>/dev/null && [ "$v1_minor" -gt "$v2_minor" ] 2>/dev/null; then
            return 0
        fi
        return 1
    fi
}

compute_sha256() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        echo ""
    fi
}

verify_file_integrity() {
    local file="$1"
    local expected_hash="${2:-}"

    local file_size
    if command -v stat &>/dev/null; then
        file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    else
        file_size=$(wc -c < "$file" 2>/dev/null || echo 0)
    fi

    if [ "$file_size" -lt 1000 ] 2>/dev/null; then
        printf "%b\n" "${RED}[ERROR] File too small (${file_size} bytes), likely corrupt.${NC}"
        return 1
    fi

    if [ -n "$expected_hash" ]; then
        local actual_hash
        actual_hash=$(compute_sha256 "$file")
        if [ -z "$actual_hash" ]; then
            printf "%b\n" "${YELLOW}[WARNING] Cannot compute SHA256, skipping hash verification.${NC}"
            return 0
        fi
        if [ "$actual_hash" != "$expected_hash" ]; then
            printf "%b\n" "${RED}[ERROR] SHA256 mismatch.${NC}"
            printf "%b\n" "${RED}  Expected: ${expected_hash}${NC}"
            printf "%b\n" "${RED}  Got:      ${actual_hash}${NC}"
            return 1
        fi
        log_msg "INFO" "SHA256 verification passed"
    fi
    return 0
}

# ==========================================
# Section 9: Spinner Animation (Hybrid POSIX Shell Compatible)
# ==========================================
_spin_inner() {
    local msg="$1"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while true; do
        local idx=$((i % ${#chars}))
        local char="${chars:$idx:1}"
        printf "\r\033[0;36m%s %s\033[0m" "$char" "$msg"
        sleep 0.1
        i=$((i + 1))
    done
}

start_spin() {
    if is_minimal; then
        printf "%b\n" "${CYAN}$1${NC}"
        return
    fi
    _spin_inner "$1" &
    SPIN_PID=$!
}

end_spin() {
    if is_minimal; then
        local _es_status="$1"
        shift
        local _es_msg="$*"
        case "$_es_status" in
            SUCCESS) printf "%b\n" "${GREEN}[OK] ${_es_msg}${NC}" ;;
            FAILED)  printf "%b\n" "${RED}[FAIL] ${_es_msg}${NC}" ;;
            *)       printf "%b\n" "${_es_msg}" ;;
        esac
        return
    fi
    if [ -n "$SPIN_PID" ] && kill -0 "$SPIN_PID" 2>/dev/null; then
        kill "$SPIN_PID" 2>/dev/null
        wait "$SPIN_PID" 2>/dev/null || true
        SPIN_PID=""
    fi
    printf "\r\033[K"
    local status="$1"
    shift
    local msg="$*"
    case "$status" in
        SUCCESS) printf "%b\n" "${GREEN}[✓] ${msg}${NC}" ;;
        FAILED)  printf "%b\n" "${RED}[✗] ${msg}${NC}" ;;
        *)       printf "%b\n" "${msg}" ;;
    esac
}

# ==========================================
# Section 10: Process Management
# ==========================================
safe_kill() {
    local pid="$1"
    [[ ! "$pid" =~ ^[0-9]+$ ]] && return 1
    [ ! -d "/proc/$pid" ] 2>/dev/null && return 1
    kill -0 "$pid" 2>/dev/null || return 1

    local is_valid=false
    local comm="" exe="" cmdline=""

    if [ -f "/proc/$pid/comm" ]; then
        read -r comm < "/proc/$pid/comm" 2>/dev/null || comm=""
    fi
    if [ -L "/proc/$pid/exe" ]; then
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    fi
    if [ -f "/proc/$pid/cmdline" ]; then
        cmdline=$(tr -d '\0' < "/proc/$pid/cmdline" 2>/dev/null)
    fi
    if [ -z "$comm" ] && command -v ps &>/dev/null; then
        comm=$(ps -p "$pid" -o comm= 2>/dev/null)
    fi

    if [[ "$comm" == *"wireproxy"* ]] || [[ "$exe" == *"wireproxy"* ]] || [[ "$cmdline" == *"wireproxy"* ]]; then
        is_valid=true
    fi

    if [ "$is_valid" = true ]; then
        kill -15 "$pid" 2>/dev/null
        local i
        for ((i = 1; i <= 6; i++)); do
            kill -0 "$pid" 2>/dev/null || return 0
            sleep 0.5
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
}

port_in_use() {
    local port="$1"
    local hex_port
    hex_port=$(printf '%04X' "$port")

    # Parse /proc/net/tcp[6] precisely by column (local_address is field 2,
    # connection state is field 4) instead of loose substring matching.
    # A naive "does 0A appear anywhere after the port" check produces
    # frequent false positives: hex remote-address bytes or queue/timer
    # fields can easily contain the substring "0A" for connections that
    # are NOT actually LISTEN sockets on our port (e.g. remote address
    # 0A684FA0:01BB is an ESTABLISHED connection, state 01, yet the "0A"
    # from its own IP would wrongly match the old pattern).
    local f
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -f "$f" ] || continue
        if awk -v want="$hex_port" '
            NR > 1 {
                split($2, la, ":")
                if (la[2] == want && $4 == "0A") { found=1; exit }
            }
            END { exit(found ? 0 : 1) }
        ' "$f" 2>/dev/null; then
            return 0
        fi
    done

    if command -v ss &>/dev/null; then
        ss -H -tln 2>/dev/null | awk -v p=":$1" '$4 ~ (p"$") { found=1; exit } END { exit(found?0:1) }' && return 0
    fi

    # NOTE: BusyBox's lsof does not implement the -i / -sTCP:LISTEN filters.
    # It silently ignores them and dumps every open file descriptor on the
    # system instead, which is always non-empty and always exits 0 -- so a
    # bare "lsof -i :$port -sTCP:LISTEN && return 0" check is a permanent
    # false positive on BusyBox systems (reports every port as in-use, e.g.
    # even port 1, which is never listening). Requiring "LISTEN" to
    # literally appear in the output filters this out: real lsof always
    # prints a LISTEN state column for a listening socket, while BusyBox's
    # unfiltered fd dump never contains that word.
    if command -v lsof &>/dev/null; then
        lsof -i :"$port" -sTCP:LISTEN 2>/dev/null | grep -q "LISTEN" && return 0
    fi
    if command -v netstat &>/dev/null; then
        netstat -an 2>/dev/null | grep -q -E "LISTEN.*[.:]$port\b" && return 0
    fi
    return 1
}

wait_for_port() {
    local port="$1"
    local max_wait="${2:-10}"
    local interval="${3:-0.5}"
    local i
    for ((i = 1; i <= max_wait * 2; i++)); do
        port_in_use "$port" && return 0
        sleep "$interval"
    done
    return 1
}

# Opposite of wait_for_port: waits until the port becomes FREE instead of
# waiting until it becomes listening. Used after stopping a service, where
# we need to confirm the OS actually released the socket before treating
# that port as available again.
wait_for_port_free() {
    local port="$1"
    local max_wait="${2:-10}"
    local interval="${3:-0.5}"
    local i
    for ((i = 1; i <= max_wait * 2; i++)); do
        port_in_use "$port" || return 0
        sleep "$interval"
    done
    return 1
}

# ==========================================
# Section 11: Status Checks
# ==========================================
dexter_warp_is_installed() {
    local wbin
    wbin=$(get_wireproxy_bin_path)
    [ -x "$wbin" ] || command -v wireproxy >/dev/null 2>&1
}

dexter_warp_is_connected() {
    local pid_file
    pid_file=$(get_pid_path)
    if [ -f "$pid_file" ]; then
        local pid=""
        read -r pid < "$pid_file" 2>/dev/null || pid=""
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            local comm=""
            if [ -f "/proc/$pid/comm" ]; then
                read -r comm < "/proc/$pid/comm" 2>/dev/null || comm=""
            elif command -v ps &>/dev/null; then
                comm=$(ps -p "$pid" -o comm= 2>/dev/null)
            fi
            if [[ "$comm" == *"wireproxy"* ]]; then
                port_in_use "$SOCKS5_PORT" && return 0
            fi
        fi
    fi
    pgrep wireproxy &>/dev/null && port_in_use "$SOCKS5_PORT"
}

# ==========================================
# Section 12: IP Cache System (Survives Connection Drops)
# ==========================================
write_cache() {
    local ip="$1"
    local country="${2:-}"
    [ -z "$ip" ] && return
    mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
    printf '%s\n%s\n%s\n' "$ip" "$(date +%s)" "$country" > "$CACHE_FILE" 2>/dev/null
    CACHED_IP="$ip"
    CACHED_COUNTRY="$country"
    LAST_IP_CHECK=$(date +%s)
}

read_cache() {
    if [ -f "$CACHE_FILE" ]; then
        local cached_ip="" cached_time="" cached_country=""
        { read -r cached_ip; read -r cached_time; read -r cached_country; } < "$CACHE_FILE" 2>/dev/null
        if [ -n "$cached_ip" ] && [[ "$cached_time" =~ ^[0-9]+$ ]]; then
            local now
            now=$(date +%s)
            local age=$((now - cached_time))
            if [ "$age" -lt "$IP_CACHE_TTL" ] 2>/dev/null; then
                CACHED_IP="$cached_ip"
                CACHED_COUNTRY="$cached_country"
                LAST_IP_CHECK="$cached_time"
                echo "$cached_ip"
                return 0
            fi
        fi
    fi
    return 1
}

invalidate_cache() {
    rm -f "$(get_cache_path)" 2>/dev/null
    CACHED_IP=""
    CACHED_COUNTRY=""
}

# ==========================================
# Section 13: External IP Detection
# ==========================================
dexter_warp_get_out_ip() {
    local ip=""
    local proxy_args="--socks5 ${PROXY_IP}:${SOCKS5_PORT}"
    ip=$(http_get "https://api.ipify.org" $proxy_args 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(http_get "https://icanhazip.com" $proxy_args 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        local trace_result
        trace_result=$(http_get "https://1.1.1.1/cdn-cgi/trace" $proxy_args 2>/dev/null)
        if [ -n "$trace_result" ]; then
            ip="${trace_result##*ip=}"
            ip="${ip%% *}"
        fi
    fi
    # NOTE: there used to be a final fallback here that queried
    # api.ipify.org WITHOUT $proxy_args. If all three proxied attempts
    # above failed, that fallback silently made a DIRECT (non-WARP)
    # request and reported the server's own real IP as if it were the
    # WARP exit IP -- a false "success" that actively hides a broken
    # proxy instead of reporting the failure. Removed: if none of the
    # proxied checks succeed, this function now correctly returns
    # failure rather than masking it with the wrong IP.
    ip="${ip%%$'\n'}"
    ip="${ip%%$'\r'}"
    ip="${ip#"${ip%%[![:space:]]*}"}"
    ip="${ip%"${ip##*[![:space:]]}"}"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
        echo "$ip"
        return 0
    fi
    return 1
}

dexter_warp_get_out_ip_cached() {
    # Check connect state first before retrieving cached outward SOCKS5 IP addresses
    if ! dexter_warp_is_connected; then
        echo "N/A"
        return 0
    fi
    local cached
    cached=$(read_cache)
    if [ -n "$cached" ]; then
        echo "$cached"
        return 0
    fi
    local ip
    ip=$(dexter_warp_get_out_ip)
    if [ -n "$ip" ]; then
        write_cache "$ip"
        echo "$ip"
        return 0
    fi
    return 1
}

dexter_warp_get_out_ip_and_country_cached() {
    # Same caching behavior as dexter_warp_get_out_ip_cached, but also
    # returns the exit country (from cdn-cgi/trace's loc= field) so the
    # status/menu display can show "which country am I in" without an
    # extra request on every redraw. Prints "IP|COUNTRY".
    if ! dexter_warp_is_connected; then
        echo "N/A|"
        return 0
    fi
    local cached
    cached=$(read_cache)
    if [ -n "$cached" ]; then
        printf '%s|%s\n' "$cached" "$CACHED_COUNTRY"
        return 0
    fi
    local result
    result=$(dexter_warp_get_ip_and_country)
    if [ -n "$result" ]; then
        write_cache "${result%%|*}" "${result##*|}"
        printf '%s\n' "$result"
        return 0
    fi
    echo "N/A|"
    return 1
}

cf_trace() {
    local proxy_args="$1"
    http_get "${CF_API}/trace" $proxy_args
}

# ==========================================
# Section 14: Cloudflare API
# ==========================================
cf_register() {
    local public_key="$1"
    local tos_time
    tos_time=$(date -u +%FT%T.000Z)
    local payload
    payload=$(printf '{"key":"%s","install_id":"","fcm_token":"","tos":"%s","type":"ios","locale":"en_US"}' "$public_key" "$tos_time")
    http_get "${CF_API}/reg" -X POST \
      -H "Content-Type: application/json" \
      -H "User-Agent: okhttp/3.12.1" \
      -d "$payload"
}

cf_update() {
    local id="$1"
    local token="$2"
    http_get "${CF_API}/reg/${id}" -X PATCH \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${token}" \
      -H "User-Agent: okhttp/3.12.1" \
      -d '{"warp_enabled":true}'
}

cf_delete() {
    local id="$1"
    local token="$2"
    http_get "${CF_API}/reg/${id}" -X DELETE \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${token}" \
      -H "User-Agent: okhttp/3.12.1"
}

parse_cf_response() {
    local response="$1"
    local field="$2"
    if command -v jq &>/dev/null; then
        echo "$response" | jq -r "$field" 2>/dev/null
        return
    fi
    local key="${field##*.}"
    local flat
    flat=$(printf '%s' "$response" | tr -d '\n\r\t' 2>/dev/null)
    local pattern="\"${key}\"[[:space:]]*:[[:space:]]*\""
    local after="${flat#*${pattern}}"
    if [ "$after" != "$flat" ]; then
        local val="${after%%\"*}"
        printf '%s' "$val"
    fi
}

# ==========================================
# Section 15: WireProxy Installation (Highly Robust API Fallback Flow)
# ==========================================
dexter_warp_download_wireproxy() {
    local raw_arch
    raw_arch=$(uname -m)
    local arch=""
    case "$raw_arch" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*)        arch="armv7" ;;
        armv6*)        arch="armv6" ;;
        i?86)
            printf "%b\n" "${YELLOW}[WARNING] 32-bit x86 detected. Using amd64 binary (may not work).${NC}"
            arch="amd64" ;;
        riscv64)       arch="riscv64" ;;
        *)
            printf "%b\n" "${RED}[ERROR] Unsupported architecture: ${raw_arch}${NC}"
            return 1
            ;;
    esac

    # NOTE: octeep/wireproxy (the original, archived upstream) has NO
    # support for SOCKS5 UDP ASSOCIATE at all -- its SOCKS5 server only
    # implements TCP CONNECT. This is a hard limitation of that specific
    # binary, not something fixable from this script. In practice this
    # means any UDP traffic sent to the SOCKS5 proxy (most commonly DNS
    # queries relayed through it by clients like Xray's "socks" outbound)
    # would silently hang until the caller's own timeout, even though TCP
    # traffic worked fine. windtf/wireproxy is the actively maintained
    # continuation of the same project and added real UDP ASSOCIATE
    # support via go-socks5 (v0.1.0+, which also fixed an earlier
    # unauthenticated-bind security issue in that same feature). Using it
    # lets a plain [Socks5] outbound with no special routing rules handle
    # both TCP and UDP correctly. We still fall back to the old
    # octeep/pufferffish binaries if windtf is ever unreachable, so
    # installs don't hard-fail over this.
    local direct_url="https://github.com/windtf/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
    local mirror_url="https://mirror.ghproxy.com/${direct_url}"
    local fallback_url="https://github.com/octeep/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
    local fallback_url2="https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
    local temp_archive="/tmp/wireproxy_$$.tar.gz"
    local extract_dir="/tmp/wp_extract_$$"
    TEMP_DIRS+=("$extract_dir")
    local bin_path
    bin_path=$(get_wireproxy_bin_path)
    local install_dir
    install_dir=$(dirname "$bin_path")

    http_download "$direct_url" -o "$temp_archive" 2>/dev/null || \
    http_download "$mirror_url" -o "$temp_archive" 2>/dev/null || \
    http_download "$fallback_url" -o "$temp_archive" 2>/dev/null || \
    http_download "$fallback_url2" -o "$temp_archive" 2>/dev/null || {
        rm -f "$temp_archive" 2>/dev/null
        return 1
    }

    if ! verify_file_integrity "$temp_archive"; then
        rm -f "$temp_archive" 2>/dev/null
        return 1
    fi

    mkdir -p "$extract_dir" 2>/dev/null || true
    if ! tar -xzf "$temp_archive" -C "$extract_dir" 2>/dev/null; then
        rm -f "$temp_archive" 2>/dev/null
        rm -rf "$extract_dir" 2>/dev/null
        return 1
    fi
    rm -f "$temp_archive" 2>/dev/null

    # POSIX compliant binary location parser (fixes the BusyBox ash double asterisk bug)
    local found_bin=""
    found_bin=$(find "$extract_dir" -type f -name "wireproxy" | head -n1 2>/dev/null)
    if [ -z "$found_bin" ] || [ ! -f "$found_bin" ]; then
        rm -rf "$extract_dir" 2>/dev/null
        return 1
    fi

    if ! chmod +x "$found_bin" 2>/dev/null; then
        rm -rf "$extract_dir" 2>/dev/null
        return 1
    fi

    if ! "$found_bin" -h &>/dev/null; then
        printf "%b\n" "${RED}[ERROR] Downloaded binary is not compatible with this system.${NC}"
        rm -rf "$extract_dir" 2>/dev/null
        return 1
    fi

    mkdir -p "$install_dir" 2>/dev/null || true
    local backup_bin="${bin_path}.bak"
    [ -f "$bin_path" ] && cp "$bin_path" "$backup_bin" 2>/dev/null || true

    if cp "$found_bin" "${bin_path}.tmp" 2>/dev/null && \
       chmod +x "${bin_path}.tmp" 2>/dev/null && \
       mv -f "${bin_path}.tmp" "$bin_path" 2>/dev/null; then
        rm -rf "$extract_dir" 2>/dev/null
        rm -f "$backup_bin" 2>/dev/null
        return 0
    else
        [ -f "$backup_bin" ] && mv -f "$backup_bin" "$bin_path" 2>/dev/null || true
        rm -rf "$extract_dir" 2>/dev/null
        return 1
    fi
}

# ==========================================
# Section 16: Service Management (Unified)
# ==========================================
_service_start() {
    _service_stop 2>/dev/null

    if [ "$CURRENT_MODE" = "VPS" ]; then
        if [ "$IS_ALPINE" = true ] && [ -f /etc/init.d/wireproxy ] && command -v rc-service &>/dev/null; then
            rc-service wireproxy start 2>/dev/null
            sleep 1
            port_in_use "$SOCKS5_PORT" && return 0
            log_msg "WARNING" "OpenRC service start may have failed"
            return 1
        fi
        if [ -f /etc/systemd/system/wireproxy.service ] && command -v systemctl &>/dev/null; then
            systemctl start wireproxy 2>/dev/null
            sleep 1
            port_in_use "$SOCKS5_PORT" && return 0
            log_msg "WARNING" "Systemd service start may have failed"
            return 1
        fi
    fi
    local pid_file
    pid_file=$(get_pid_path)
    if port_in_use "$SOCKS5_PORT" 2>/dev/null; then
        log_msg "WARNING" "Port $SOCKS5_PORT still in use after stop, waiting..."
        sleep 2
    fi

    # Validate the config before launching, so a bad config gives a clear
    # error instead of a silent crash-on-launch.
    local configtest_out
    configtest_out=$("$WIREPROXY_BIN" -c "$WIREPROXY_CONF" -n 2>&1)
    if [ $? -ne 0 ]; then
        log_msg "ERROR" "WireProxy config is invalid (wireproxy -n): ${configtest_out:-no output}"
        return 1
    fi

    local wireproxy_err_log
    wireproxy_err_log="${CACHE_DIR}/wireproxy-last-error.log"
    # CACHE_DIR can be deleted mid-session by "Remove WARP" (option 4),
    # which does "rm -rf" on this exact directory. _ensure_dirs only runs
    # once at script startup, so a remove-then-reinstall within the same
    # menu session left this directory missing -- writing here then
    # failed silently, which made wireproxy's own stdout/stderr redirect
    # target invalid, causing it to die immediately on launch with no
    # captured output. Recreate defensively every time instead of
    # assuming it still exists.
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    : > "$wireproxy_err_log" 2>/dev/null

    nohup "$WIREPROXY_BIN" -c "$WIREPROXY_CONF" >"$wireproxy_err_log" 2>&1 &
    local new_pid=$!
    # Detach fully from this shell's job table. Combined with the
    # safe_cleanup fix above, this is a second layer of protection so the
    # tunnel process survives menu exit, Ctrl+C, and SSH disconnects.
    disown "$new_pid" 2>/dev/null || disown 2>/dev/null || true
    printf '%s\n' "$new_pid" > "$pid_file" 2>/dev/null
    sleep 1
    if ! kill -0 "$new_pid" 2>/dev/null; then
        local crash_out
        crash_out=$(tr -s '\n' ' ' < "$wireproxy_err_log" 2>/dev/null)
        log_msg "ERROR" "WireProxy process died immediately after launch | exit_output=\"${crash_out:-no output captured}\""
        return 1
    fi
    return 0
}

_service_stop() {
    if [ "$CURRENT_MODE" = "VPS" ]; then
        if [ "$IS_ALPINE" = true ] && [ -f /etc/init.d/wireproxy ] && command -v rc-service &>/dev/null; then
            rc-service wireproxy stop &>/dev/null || true
            wait_for_port_free "$SOCKS5_PORT" 10 0.5
            return
        fi
        if [ -f /etc/systemd/system/wireproxy.service ] && command -v systemctl &>/dev/null; then
            systemctl stop wireproxy &>/dev/null || true
            wait_for_port_free "$SOCKS5_PORT" 10 0.5
            return
        fi
    fi
    local pid_file
    pid_file=$(get_pid_path)
    if [ -f "$pid_file" ]; then
        local pid=""
        read -r pid < "$pid_file" 2>/dev/null || pid=""
        [ -n "$pid" ] && safe_kill "$pid"
        rm -f "$pid_file" 2>/dev/null
    else
        pkill -f "wireproxy.*-c.*${WIREPROXY_CONF}" 2>/dev/null || pkill -x wireproxy 2>/dev/null || true
    fi
    wait_for_port_free "$SOCKS5_PORT" 10 0.5
}

# ==========================================
# Section 17: Service Installation
# ==========================================
dexter_warp_install_service() {
    if is_minimal || [ "$RUN_MODE" = "Container" ]; then return 0; fi
    local wbin wconf
    wbin=$(get_wireproxy_bin_path)
    wconf=$(get_wireproxy_conf_path)

    if [ "$IS_ALPINE" = true ]; then
        if [ -d /etc/init.d ] && [ ! -f /etc/init.d/wireproxy ]; then
            printf "%b\n" "${CYAN}Installing OpenRC service definition...${NC}"
            cat <<OPENRC_EOF > /etc/init.d/wireproxy
#!/sbin/openrc-run
description="Cloudflare WARP WireProxy Daemon"
command="${wbin}"
command_args="-c ${wconf}"
pidfile="/run/wireproxy.pid"
background=yes
depend() {
    need net
}
OPENRC_EOF
            chmod +x /etc/init.d/wireproxy
            rc-update add wireproxy default 2>/dev/null || true
            log_msg "INFO" "OpenRC service deployed"
        fi
    else
        if [ -d /etc/systemd/system ] && [ ! -f /etc/systemd/system/wireproxy.service ]; then
            printf "%b\n" "${CYAN}Installing Systemd service definition...${NC}"
            local svc_file="/etc/systemd/system/wireproxy.service"
            cat <<EOF > "$svc_file"
[Unit]
Description=Cloudflare WARP WireProxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${wbin} -c ${wconf}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc /var/log /var/cache /tmp /run

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload 2>/dev/null || true
            systemctl enable wireproxy 2>/dev/null || true
            log_msg "INFO" "Systemd service deployed"
        fi
    fi
}

# ==========================================
# Section 18: OS Detection
# ==========================================
dexter_warp_check_os() {
    detect_os
    if [ -f /etc/os-release ]; then
        local id=""
        id=$(awk -F= '$1=="ID" {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
        case "$id" in
            ubuntu|debian|alpine|centos|rhel|fedora|arch|manjaro|pop|linuxmint|void)
                return 0 ;;
        esac
        local id_like=""
        id_like=$(awk -F= '$1=="ID_LIKE" {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || true)
        if [[ "$id_like" == *debian* ]] || [[ "$id_like" == *ubuntu* ]] || [[ "$id_like" == *rhel* ]] || [[ "$id_like" == *alpine* ]]; then
            return 0
        fi
    fi
    if [ -f /etc/alpine-release ]; then
        return 0
    fi
    if [ -f /etc/debian_version ] || [ -f /etc/redhat-release ]; then
        return 0
    fi
    printf "%b\n" "${YELLOW}[WARNING] OS '${id:-unknown}' not explicitly supported. Continuing anyway.${NC}"
    return 0
}

# ==========================================
# Section 19: Dependency Installation
# ==========================================
dexter_warp_install_alpine_deps() {
    apk update || return 1
    apk add curl jq wireguard-tools openssl || return 1
}

dexter_warp_install_debian_deps() {
    apt-get update -qq || log_msg "WARNING" "apt update returned error"
    apt-get install -y -qq curl jq wireguard-tools ca-certificates || return 1
}

dexter_warp_install() {
    if dexter_warp_is_installed && dexter_warp_is_connected; then
        printf "%b\n" "${GREEN}WARP is already installed and connected.${NC}"
        read -r -p "Do you want to reinstall it? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi

    if [ "$IS_ALPINE" = true ]; then
        dexter_warp_install_alpine_deps || return 1
    else
        dexter_warp_install_debian_deps || return 1
    fi

    start_spin "${T[wp_dl]}"
    if dexter_warp_download_wireproxy; then
        end_spin "SUCCESS" "${T[wp_ok]}"
    else
        end_spin "FAILED" "${T[wp_fail]}"
        return 1
    fi
    dexter_warp_install_service
    dexter_warp_connect
}

# ==========================================
# Section 20: Connection & Self-Healing (Resilient API abstraction with Exponential Backoff)
# ==========================================
dexter_warp_register_api() {
    local private_key=""
    private_key=$(wg genkey 2>/dev/null) || private_key=""
    if [ -z "$private_key" ]; then
        log_msg "WARNING" "'wg genkey' unavailable or failed, falling back to openssl/dd (note: this key will NOT work with 'wg pubkey' unless wireguard-tools is installed)"
        private_key=$(openssl rand -base64 32 2>/dev/null || dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 2>/dev/null | tr -d '\r\n')
    fi

    if [ -z "$private_key" ]; then
        log_msg "ERROR" "Key generation failed: neither 'wg genkey', 'openssl rand', nor 'dd' produced a key. Is wireguard-tools/openssl installed?"
        printf "%b\n" "${RED}[ERROR] WireGuard key generation failed.${NC}"
        return 1
    fi

    local public_key=""
    public_key=$(printf '%s' "$private_key" | wg pubkey 2>/dev/null)

    if [ -z "$public_key" ]; then
        log_msg "ERROR" "Public key derivation failed: '$(command -v wg 2>/dev/null || echo "wg command not found")' could not derive pubkey from the generated private key."
        printf "%b\n" "${RED}[ERROR] WireGuard public key derivation failed.${NC}"
        return 1
    fi

    local response=""
    local success=false
    local attempt

    for attempt in 1 2 3; do
        if ! check_internet; then
            log_msg "WARNING" "No internet during registration attempt $attempt (see check_internet failure above for curl details)"
            local backoff=$((attempt * 3))
            sleep "$backoff"
            continue
        fi
        response=$(cf_register "$public_key")
        local cf_exit=$?

        if [ -n "$response" ] && [ "$response" != "null" ]; then
            local check_id
            if command -v jq &>/dev/null; then
                check_id=$(echo "$response" | jq -r '.id // .result.id // empty' 2>/dev/null)
            else
                check_id=$(echo "$response" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
            fi
            if [[ -n "$check_id" ]] && [ "$check_id" != "null" ]; then
                success=true
                break
            else
                log_msg "ERROR" "Registration attempt $attempt: Cloudflare responded but no 'id' field found | curl_exit=${cf_exit} | response=\"${response}\""
            fi
        else
            log_msg "ERROR" "Registration attempt $attempt: empty/null response from Cloudflare API | curl_exit=${cf_exit} (see http_get failure log above for exact reason)"
        fi
        sleep "$((attempt * 2))"
    done

    if [ "$success" = false ]; then
        log_msg "ERROR" "Cloudflare registration failed after 3 attempts. Check the http_get/check_internet error lines above this for the exact curl exit code, HTTP code and stderr message."
        return 1
    fi


    WG_PRIV_KEY="$private_key"

    if command -v jq &>/dev/null; then
        WG_PEER_PUB_KEY=$(echo "$response" | jq -r '.config.peers[0].public_key // .result.config.peers[0].public_key // empty' 2>/dev/null)
        WG_PEER_ENDPOINT=$(echo "$response" | jq -r '.config.peers[0].endpoint.v4 // .result.config.peers[0].endpoint.v4 // empty' 2>/dev/null)
        WG_IPV4=$(echo "$response" | jq -r '.config.interface.addresses.v4 // .result.config.interface.addresses.v4 // empty' 2>/dev/null)
        WG_IPV6=$(echo "$response" | jq -r '.config.interface.addresses.v6 // .result.config.interface.addresses.v6 // empty' 2>/dev/null)
        WG_REG_ID=$(echo "$response" | jq -r '.id // .result.id // empty' 2>/dev/null)
        WG_REG_TOKEN=$(echo "$response" | jq -r '.token // .result.token // empty' 2>/dev/null)
    else
        log_msg "WARNING" "jq not available, using grep/sed fallback for JSON parsing"
        WG_PEER_PUB_KEY=$(echo "$response" | grep -o '"public_key"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
        WG_PEER_ENDPOINT=$(echo "$response" | grep -o '"v4"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
        WG_IPV4=$(echo "$response" | grep -o '"v4"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | sed -n 2p | sed 's/.*"\([^"]*\)"$/\1/')
        WG_IPV6=$(echo "$response" | grep -o '"v6"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | sed -n 2p | sed 's/.*"\([^"]*\)"$/\1/')
        WG_REG_ID=$(echo "$response" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
        WG_REG_TOKEN=$(echo "$response" | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi

    [ -z "$WG_PEER_PUB_KEY" ] || [ "$WG_PEER_PUB_KEY" = "null" ] && { log_msg "ERROR" "Invalid peer public key from API"; return 1; }
    [ -z "$WG_PEER_ENDPOINT" ] || [ "$WG_PEER_ENDPOINT" = "null" ] && { log_msg "ERROR" "Invalid endpoint from API"; return 1; }
    [ -z "$WG_IPV4" ] || [ "$WG_IPV4" = "null" ] && { log_msg "ERROR" "Invalid IPv4 from API"; return 1; }

    # Cloudflare's registration API always returns the endpoint with port 0
    # (e.g. "162.159.192.5:0") as a placeholder; the real port must come
    # from its known-good WARP port list. Swap it in here so the very first
    # config we write is already usable instead of relying on a later
    # self-heal pass to fix it.
    local ep_host="${WG_PEER_ENDPOINT%%:*}"
    local ep_port="${WG_PEER_ENDPOINT##*:}"
    if [ -z "$ep_port" ] || [ "$ep_port" = "0" ] || ! [[ "$ep_port" =~ ^[0-9]+$ ]]; then
        WG_PEER_ENDPOINT="${ep_host}:2408"
        log_msg "INFO" "Replaced placeholder endpoint port with default 2408 (was \"${ep_host}:${ep_port}\")"
    fi

    save_config
    dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
}

dexter_warp_generate_wireproxy_conf() {
    local ipv4="$1"
    local private_key="$2"
    local peer_pubkey="$3"
    local peer_endpoint="$4"
    local ipv6="$5"

    local address_line=""
    local dns_servers=""
    local allowed_ips="0.0.0.0/0"

    case "$IP_VERSION" in
        4)
            address_line="${ipv4}/32"
            # 1.1.1.1 is Cloudflare's public resolver meant to be reached
            # FROM OUTSIDE a WARP tunnel; querying it FROM INSIDE the
            # tunnel is known to be unreliable (silent timeouts) for some
            # registrations. 162.159.36.1 is Cloudflare's WARP-internal
            # DNS proxy, meant specifically for in-tunnel resolution.
            dns_servers="162.159.36.1"
            allowed_ips="0.0.0.0/0"
            ;;
        6)
            if ! check_ipv6_available; then
                printf "%b\n" "${YELLOW}[WARNING] IPv6 not available on this system. Falling back to IPv4.${NC}"
                IP_VERSION="4"
                address_line="${ipv4}/32"
                dns_servers="162.159.36.1"
                allowed_ips="0.0.0.0/0"
            else
                address_line="${ipv6}/128"
                dns_servers="2606:4700:4700::1111"
                allowed_ips="::/0"
            fi
            ;;
        dual)
            if check_ipv6_available; then
                address_line="${ipv4}/32, ${ipv6}/128"
                dns_servers="162.159.36.1, 2606:4700:4700::1111"
                allowed_ips="0.0.0.0/0, ::/0"
            else
                address_line="${ipv4}/32"
                dns_servers="162.159.36.1"
                allowed_ips="0.0.0.0/0"
            fi
            ;;
    esac

    mkdir -p "$(dirname "$WIREPROXY_CONF")" 2>/dev/null || true
    local tmp_conf="${WIREPROXY_CONF}.tmp.$$"
    cat <<EOF > "$tmp_conf"
[Interface]
PrivateKey = $private_key
Address = $address_line
DNS = $dns_servers
MTU = ${WG_MTU:-$DEFAULT_WG_MTU}

[Peer]
PublicKey = $peer_pubkey
Endpoint = $peer_endpoint
AllowedIPs = $allowed_ips
PersistentKeepalive = 25

[Socks5]
BindAddress = $PROXY_IP:$SOCKS5_PORT
EOF
    if mv -f "$tmp_conf" "$WIREPROXY_CONF" 2>/dev/null; then
        chmod 600 "$WIREPROXY_CONF" 2>/dev/null || true
        log_msg "INFO" "wireproxy config written with 600 permissions"
    else
        rm -f "$tmp_conf" 2>/dev/null
        log_msg "ERROR" "Failed to write wireproxy config"
    fi
}

dexter_warp_verify_connection_traffic() {
    local proxy_args="--socks5 ${PROXY_IP}:${SOCKS5_PORT}"
    local endpoints=(
        "${CF_API}/trace"
        "https://www.cloudflare.com/cdn-cgi/trace"
        "https://icanhazip.com"
    )
    local ep
    for ep in "${endpoints[@]}"; do
        local result
        # Traffic through a freshly-started WireGuard tunnel is noticeably
        # slower than a direct request (first handshake + route setup);
        # give it real headroom instead of the tight 3s/5s defaults used
        # for plain connectivity checks, and skip curl's own --retry so
        # the full budget goes to one attempt per endpoint.
        result=$(HTTP_CONNECT_TIMEOUT=5 HTTP_MAX_TIME=12 HTTP_RETRY=0 http_get "$ep" $proxy_args 2>/dev/null)
        if [ -n "$result" ]; then
            return 0
        fi
    done
    return 1
}

dexter_warp_verify_wireproxy_connection() {
    local listening=false
    is_minimal || printf "%b\n" "${CYAN}Verifying port $SOCKS5_PORT listening state...${NC}"

    if wait_for_port "$SOCKS5_PORT" 10 0.5; then
        listening=true
    fi

    if [ "$listening" = false ]; then
        log_msg "WARNING" "Port listening verify timeout"
        return 1
    fi

    # Port being open just means wireproxy's SOCKS5 listener is up; the
    # WireGuard handshake and internal routing can still be settling for a
    # moment after that, so give it a brief head start before hammering it
    # with the traffic check below.
    sleep 2

    is_minimal || printf "%b\n" "${CYAN}Verifying SOCKS5 traffic flow...${NC}"
    local proxy_ok=false
    local i
    for ((i = 1; i <= 5; i++)); do
        if dexter_warp_verify_connection_traffic; then
            proxy_ok=true
            break
        fi
        sleep 1
    done

    if [ "$proxy_ok" = false ]; then
        log_msg "WARNING" "SOCKS5 traffic check failed. Starting self-healing..."
        _self_heal_recovery
        return $?
    fi

    log_msg "INFO" "WireProxy SOCKS5 verified active"
    _reset_self_heal_state
    return 0
}

_self_heal_recovery() {
    local now
    now=$(date +%s)

    if [ "$SELF_HEAL_COOLDOWN" -gt 0 ] 2>/dev/null && [ "$now" -lt "$SELF_HEAL_COOLDOWN" ] 2>/dev/null; then
        local remaining=$((SELF_HEAL_COOLDOWN - now))
        log_msg "WARNING" "Self-healing in cooldown for ${remaining}s"
        return 1
    fi

    if [ "$SELF_HEAL_RETRY_COUNT" -ge "$SELF_HEAL_MAX_RETRIES" ] 2>/dev/null; then
        log_msg "ERROR" "Self-healing retry limit reached ($SELF_HEAL_MAX_RETRIES). Manual intervention required."
        SELF_HEAL_COOLDOWN=$((now + 300))
        _reset_self_heal_state
        is_minimal || printf "%b\n" "${RED}[ERROR] Too many recovery attempts. Cooling down for 5 minutes.${NC}"
        return 1
    fi

    if [ "$SELF_HEAL_CONSECUTIVE_FAIL" -ge "$SELF_HEAL_MAX_CONSECUTIVE" ] 2>/dev/null; then
        log_msg "ERROR" "Self-healing consecutive failure limit reached ($SELF_HEAL_MAX_CONSECUTIVE)."
        SELF_HEAL_COOLDOWN=$((now + 600))
        _reset_self_heal_state
        is_minimal || printf "%b\n" "${RED}[ERROR] Too many consecutive failures. Cooling down for 10 minutes.${NC}"
        return 1
    fi

    is_minimal || printf "%b\n" "${YELLOW}[Auto-Recovery] Stage 1: Restarting service...${NC}"
    log_msg "INFO" "Self-healing stage 1: restarting wireproxy"
    dexter_warp_disconnect
    _service_start
    sleep 2

    local i
    for ((i = 1; i <= 5; i++)); do
        if dexter_warp_verify_connection_traffic; then
            is_minimal || printf "%b\n" "${GREEN}[✓] Recovery succeeded via restart.${NC}"
            log_msg "INFO" "Self-healing succeeded via restart"
            _reset_self_heal_state
            return 0
        fi
        sleep 1
    done

    # Self-healing exponential backoff calculations
    SELF_HEAL_RETRY_COUNT=$((SELF_HEAL_RETRY_COUNT + 1))
    SELF_HEAL_CONSECUTIVE_FAIL=$((SELF_HEAL_CONSECUTIVE_FAIL + 1))

    local base_backoff=$((SELF_HEAL_BACKOFF * 2 + 5))
    local rand_val
    rand_val=$(get_random)
    local jitter=$((rand_val % 10))
    SELF_HEAL_BACKOFF=$((base_backoff + jitter))
    [ "$SELF_HEAL_BACKOFF" -gt "$SELF_HEAL_MAX_BACKOFF" ] && SELF_HEAL_BACKOFF="$SELF_HEAL_MAX_BACKOFF"
    now=$(date +%s)

    local conn_status
    conn_status=$(check_connectivity_full)
    if [ "$conn_status" != "ok" ]; then
        log_msg "WARNING" "Network unreachable (${conn_status}). Skipping identity re-registration."
        is_minimal || printf "%b\n" "${YELLOW}[Auto-Recovery] No internet (${conn_status}). Retrying in ${SELF_HEAL_BACKOFF}s...${NC}"
        SELF_HEAL_COOLDOWN=$((now + SELF_HEAL_BACKOFF))
        return 1
    fi

    is_minimal || printf "%b\n" "${YELLOW}[Auto-Recovery] Stage 2: WAN up but proxy dead. Re-registering identity...${NC}"
    log_msg "INFO" "Self-healing: attempting identity re-registration (attempt $SELF_HEAL_RETRY_COUNT)"

    if [ -n "$WG_REG_ID" ] && [ -n "$WG_REG_TOKEN" ]; then
        cf_delete "$WG_REG_ID" "$WG_REG_TOKEN" >/dev/null 2>&1 || true
    fi
    rm -f "$(get_wireproxy_conf_path)" 2>/dev/null

    if dexter_warp_register_api; then
        _service_start
        sleep 2
        for ((i = 1; i <= 5; i++)); do
            if dexter_warp_verify_connection_traffic; then
                is_minimal || printf "%b\n" "${GREEN}[✓] Recovery succeeded via re-registration.${NC}"
                log_msg "INFO" "Self-healing succeeded via re-registration"
                _reset_self_heal_state
                return 0
            fi
            sleep 1
        done
    fi

    # Set dynamic backoff cooldown
    SELF_HEAL_COOLDOWN=$((now + SELF_HEAL_BACKOFF))
    log_msg "WARNING" "Self-healing failed. Next attempt in ${SELF_HEAL_BACKOFF}s"
    is_minimal || printf "%b\n" "${YELLOW}[Auto-Recovery] Recovery failed. Retrying in ${SELF_HEAL_BACKOFF}s...${NC}"
    return 1
}

dexter_warp_connect() {
    start_spin "${T[launch]}"
    local wconf
    wconf=$(get_wireproxy_conf_path)
    local connect_ok=false

    if [ -f "$wconf" ]; then
        _service_start
        if dexter_warp_verify_wireproxy_connection; then
            connect_ok=true
        else
            log_msg "WARNING" "Existing config failed verification. Regenerating identity."
            dexter_warp_disconnect
            if [ -n "$WG_REG_ID" ] && [ -n "$WG_REG_TOKEN" ]; then
                cf_delete "$WG_REG_ID" "$WG_REG_TOKEN" >/dev/null 2>&1 || true
            fi
            rm -f "$wconf" 2>/dev/null
        fi
    fi

    if [ "$connect_ok" = false ] && [ ! -f "$wconf" ]; then
        if ! check_internet; then
            end_spin "FAILED" "${T[launch_fail]}"
            _print_last_log_hint
            return 1
        fi
        if ! dexter_warp_register_api; then
            end_spin "FAILED" "${T[reg_fail]}"
            _print_last_log_hint
            return 1
        fi
        _service_start
        if dexter_warp_verify_wireproxy_connection; then
            connect_ok=true
        fi
    fi

    if [ "$connect_ok" = true ]; then
        _reset_self_heal_state
        end_spin "SUCCESS" "${T[launch_ok]}"
        return 0
    else
        end_spin "FAILED" "${T[verify_fail]}"
        _print_last_log_hint
        return 1
    fi
}

# Shows the last few diagnostic log lines directly on screen so the real
# curl error (DNS/timeout/HTTP code/etc) is visible without digging through
# the log file manually.
_print_last_log_hint() {
    is_minimal && return 0
    local log_path
    log_path=$(get_log_path)
    printf "%b\n" "${YELLOW}---------------------------------------------------------${NC}"
    printf "%b\n" "${YELLOW}[DEBUG] Last diagnostic log lines (full log: ${log_path}):${NC}"
    if [ -f "$log_path" ]; then
        tail -n 8 "$log_path" 2>/dev/null | while IFS= read -r line; do
            printf "%b\n" "${CYAN}  ${line}${NC}"
        done
    else
        printf "%b\n" "${RED}  Log file not found at ${log_path}${NC}"
    fi
    printf "%b\n" "${YELLOW}---------------------------------------------------------${NC}"
}

dexter_warp_disconnect() {
    is_minimal || printf "%b\n" "${YELLOW}Disconnecting WARP...${NC}"
    _service_stop
    invalidate_cache
    log_msg "INFO" "Disconnected service"
}

dexter_warp_status() {
    if dexter_warp_is_connected; then
        printf "%b\n" "WARP Status: ${GREEN}CONNECTED${NC} (via WireProxy SOCKS5: ${PROXY_IP}:${SOCKS5_PORT})"
        local ip_country
        ip_country=$(dexter_warp_get_out_ip_and_country_cached 2>/dev/null)
        local out_ip="${ip_country%%|*}"
        local out_country="${ip_country##*|}"
        printf "%b\n" "Exit IP     : ${YELLOW}${out_ip:-N/A}${NC}"
        printf "%b\n" "Exit Country: ${YELLOW}${out_country:-Unknown}${NC}"
    else
        printf "%b\n" "WARP Status: ${RED}NOT CONNECTED${NC}"
    fi
}

dexter_warp_test_proxy() {
    printf "%b\n" "${CYAN}Testing SOCKS5 proxy (${PROXY_IP}:${SOCKS5_PORT})...${NC}"
    local ip
    ip=$(dexter_warp_get_out_ip)
    if [[ -n "$ip" ]]; then
        printf "%b\n" "[OK] Outgoing IP via WARP: ${GREEN}$ip${NC}"
        write_cache "$ip"
    else
        printf "%b\n" "[FAIL] ${RED}Could not get IP via proxy. Is WARP connected?${NC}"
    fi
}

dexter_warp_restart() {
    is_minimal || printf "%b\n" "${CYAN}Restarting WARP SOCKS5 service...${NC}"
    dexter_warp_disconnect
    sleep 1
    if dexter_warp_connect; then
        is_minimal || printf "%b\n" "${GREEN}[✓] WARP restarted successfully.${NC}"
    else
        is_minimal || printf "%b\n" "${RED}[ERROR] Failed to restart WARP service.${NC}"
    fi
}

dexter_warp_view_logs() {
    if is_minimal; then
        printf "%b\n" "${RED}[ERROR] Logs are disabled in Minimal Mode.${NC}"
        return 0
    fi
    local log_path
    log_path=$(get_log_path)
    printf "%b\n" "${CYAN}--- Displaying last 50 lines of Log ---${NC}"
    if [ -f "$log_path" ]; then
        tail -n 50 "$log_path"
    else
        printf "%b\n" "${YELLOW}Log file is empty or does not exist yet.${NC}"
    fi
}

# ==========================================
# Section 21: IP Rotation
# ==========================================
declare -a WARP_ENDPOINTS=(
    "162.159.192.1:2408"
    "162.159.193.1:2408"
    "162.159.195.1:2408"
    "162.159.204.1:2408"
    "162.159.205.1:2408"
    "162.159.206.1:2408"
    "engage.cloudflareclient.com:2408"
)

check_endpoint_health() {
    local endpoint="$1"
    local host="${endpoint%%:*}"
    local port="${endpoint##*:}"
    local timeout=3
    if command -v nc &>/dev/null; then
        nc -z -w "$timeout" "$host" "$port" 2>/dev/null && return 0
    elif command -v timeout &>/dev/null; then
        timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null && return 0
    else
        curl -s --max-time "$timeout" --connect-only "socks5h://${host}:${port}" 2>/dev/null && return 0
    fi
    return 1
}

get_healthy_endpoints() {
    local -a healthy=()
    local ep
    for ep in "${WARP_ENDPOINTS[@]}"; do
        if check_endpoint_health "$ep"; then
            healthy+=("$ep")
        fi
    done
    if [ ${#healthy[@]} -eq 0 ]; then
        printf '%s\n' "${WARP_ENDPOINTS[@]}"
    else
        printf '%s\n' "${healthy[@]}"
    fi
}

dexter_warp_quick_change_ip() {
    if ! dexter_warp_is_installed; then
        printf "%b\n" "${RED}WARP is not installed.${NC}"
        return 1
    fi

    if ! check_internet; then
        printf "%b\n" "${RED}No internet connection. Cannot rotate IP.${NC}"
        log_msg "WARNING" "Quick IP change aborted: no internet"
        return 1
    fi

    printf "%b\n" "${CYAN}Quick IP change via endpoint rotation...${NC}"

    invalidate_cache
    local old_ip new_ip
    old_ip=$(dexter_warp_get_out_ip)
    printf "%b\n" "Current IP: ${YELLOW}${old_ip:-N/A}${NC}"

    printf "%b\n" "${CYAN}Checking endpoint health...${NC}"
    local healthy_eps
    healthy_eps=$(get_healthy_endpoints)
    local -a endpoints_array=()
    while IFS= read -r ep; do
        [ -n "$ep" ] && endpoints_array+=("$ep")
    done <<< "$healthy_eps"

    if [ ${#endpoints_array[@]} -eq 0 ]; then
        endpoints_array=("${WARP_ENDPOINTS[@]}")
    fi

    printf "%b\n" "Available healthy endpoints: ${GREEN}${#endpoints_array[@]}${NC}"

    local attempt
    for attempt in {1..5}; do
        printf "%b\n" "Attempt ${attempt}/5: Rotating endpoint..."
        dexter_warp_disconnect

        local rand_val
        rand_val=$(get_random)
        local rand_idx=$((rand_val % ${#endpoints_array[@]}))
        local selected_endpoint="${endpoints_array[$rand_idx]}"

        printf "%b\n" "Selected endpoint: ${CYAN}${selected_endpoint}${NC}"
        local validated_ep
        validated_ep=$(validate_endpoint "$selected_endpoint")
        [ -n "$validated_ep" ] || { log_msg "WARNING" "Invalid endpoint: $selected_endpoint"; continue; }
        WG_PEER_ENDPOINT="$validated_ep"
        save_config
        dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"

        _service_start
        wait_for_port "$SOCKS5_PORT" 10 0.5

        sleep 1
        new_ip=$(dexter_warp_get_out_ip)
        if [[ -n "$new_ip" ]] && [[ "$new_ip" != "$old_ip" ]]; then
            printf "%b\n" "[✓] New IP Resolved: ${GREEN}$new_ip${NC}"
            write_cache "$new_ip"
            log_msg "INFO" "Quick IP change success. New IP: $new_ip"
            return 0
        fi
    done

    printf "%b\n" "${YELLOW}IP did not change with quick method. Try 'New Identity' option for guaranteed rotation.${NC}"
    return 2
}

dexter_warp_new_identity() {
    if ! dexter_warp_is_installed; then
        printf "%b\n" "${RED}WARP is not installed.${NC}"
        return 1
    fi

    if ! check_internet; then
        printf "%b\n" "${RED}No internet connection. Cannot create new identity.${NC}"
        log_msg "WARNING" "New identity aborted: no internet"
        return 1
    fi

    printf "%b\n" "${CYAN}Issuing fresh registration for identity change...${NC}"

    local old_ip new_ip
    old_ip=$(dexter_warp_get_out_ip)
    printf "%b\n" "Old IP: ${YELLOW}${old_ip:-N/A}${NC}"

    invalidate_cache
    dexter_warp_disconnect

    if [ -n "$WG_REG_ID" ] && [ -n "$WG_REG_TOKEN" ]; then
        printf "%b\n" "${CYAN}De-registering from Cloudflare servers...${NC}"
        cf_delete "$WG_REG_ID" "$WG_REG_TOKEN" >/dev/null 2>&1 || true
    fi
    rm -f "$(get_wireproxy_conf_path)" 2>/dev/null
    dexter_warp_connect

    sleep 1
    new_ip=$(dexter_warp_get_out_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            printf "%b\n" "[✓] New IP: ${GREEN}$new_ip${NC}"
            write_cache "$new_ip"
            log_msg "INFO" "New Identity success. IP: $new_ip"
        else
            printf "%b\n" "${YELLOW}Identity refreshed but IP unchanged. Try again later.${NC}"
        fi
    else
        printf "%b\n" "${RED}Could not obtain new IP after re-registration.${NC}"
        log_msg "ERROR" "Failed to fetch new IP after fresh registration"
        return 2
    fi
}

# ==========================================
# Section 21b: Change IP - live-updating helpers
# ==========================================
# Renders a small fixed-height block of status lines in place (like a
# mini dashboard) instead of printing a new line per attempt, which gets
# unreadable fast over 50 iterations. Call _live_block_start once, then
# _live_block_update repeatedly with the same number of lines, then
# _live_block_end when done. No-ops in minimal/non-interactive mode,
# where it just prints flat lines instead (redraw escapes don't make
# sense without a real terminal).
_LIVE_BLOCK_LINES=0
_live_block_start() {
    _LIVE_BLOCK_LINES=0
}
_live_block_update() {
    # Args: one string per line to display.
    if is_minimal; then
        printf "%b\n" "$*"
        return
    fi
    if [ "$_LIVE_BLOCK_LINES" -gt 0 ]; then
        printf "\033[%dA" "$_LIVE_BLOCK_LINES"
    fi
    local line
    for line in "$@"; do
        printf "\r\033[K%b\n" "$line"
    done
    _LIVE_BLOCK_LINES=$#
}
_live_block_end() {
    _LIVE_BLOCK_LINES=0
}

fmt_mmss() {
    local s="$1"
    printf '%02d:%02d' "$((s/60))" "$((s%60))"
}

# ==========================================
# Section 21c: Change IP by Country
# ==========================================
# Rotates through WARP_ENDPOINTS (same identity/key, different Cloudflare
# PoP) trying to land the tunnel's egress in a specific country, checked
# via cdn-cgi/trace's "loc=" field (one request gives both IP and country -
# no third-party GeoIP service needed). Caps on whichever comes first: a
# fixed attempt count or a wall-clock time budget. If the target country is
# never reached, the exact previous working config (endpoint + identity)
# is restored so the user is never left with a broken/half-rotated tunnel.
#
# NOTE ON COVERAGE: WARP_ENDPOINTS only lists a handful of Cloudflare PoP
# IPs (not the huge ranges tools like fscarmen/warp scan), so this can only
# ever reach whichever countries those specific PoPs happen to serve. It
# will not find every country no matter how many attempts are allowed -
# the failure message says so explicitly rather than implying it tried
# "everywhere". For most people, "Optimize (Best Latency)" below gives a
# genuinely better connection than picking a country by name - see its
# comment block for why.
dexter_warp_get_ip_and_country() {
    # Single cdn-cgi/trace request through the SOCKS5 proxy, using
    # --socks5-hostname so resolution happens the same way real client
    # traffic would. Prints "IP|COUNTRY" (COUNTRY may be empty/"XX").
    local trace
    trace=$(HTTP_CONNECT_TIMEOUT=5 HTTP_MAX_TIME=12 HTTP_RETRY=0 \
        http_get "https://www.cloudflare.com/cdn-cgi/trace" --socks5-hostname "${PROXY_IP}:${SOCKS5_PORT}" 2>/dev/null)
    [ -z "$trace" ] && return 1
    local ip="" loc=""
    while IFS='=' read -r k v; do
        v="${v%$'\r'}"
        case "$k" in
            ip)  ip="$v" ;;
            loc) loc="$v" ;;
        esac
    done <<< "$trace"
    [ -z "$ip" ] && return 1
    printf '%s|%s\n' "$ip" "${loc:-XX}"
}

dexter_warp_change_ip_by_country() {
    if ! dexter_warp_is_installed; then
        printf "%b\n" "${RED}WARP is not installed.${NC}"
        return 1
    fi
    if [ "$IP_VERSION" != "4" ]; then
        printf "%b\n" "${YELLOW}This feature currently only supports IPv4 Only mode.${NC}"
        printf "%b\n" "${YELLOW}Current mode: $(dexter_warp_get_mode_label). Switch via option 13 first.${NC}"
        return 1
    fi
    if ! check_internet; then
        printf "%b\n" "${RED}No internet connection.${NC}"
        return 1
    fi

    local target
    read -r -p "Target country code (2 letters, e.g. NL, DE, US): " target
    target=$(printf '%s' "$target" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z')
    if [ "${#target}" -ne 2 ]; then
        printf "%b\n" "${RED}Invalid country code. Must be exactly 2 letters.${NC}"
        return 1
    fi

    local max_attempts=50
    local max_seconds=300

    # Save last-known-good so a failed search can be reverted cleanly.
    local lkg_endpoint="$WG_PEER_ENDPOINT"
    local lkg_conf_backup
    lkg_conf_backup=$(mktemp 2>/dev/null) || lkg_conf_backup="${WIREPROXY_CONF}.lkg.$$"
    cp -f "$WIREPROXY_CONF" "$lkg_conf_backup" 2>/dev/null

    # If we're already connected and already sitting in the target
    # country, there's nothing to do -- rotating anyway would just
    # disconnect a working, already-correct tunnel for no reason.
    if dexter_warp_is_connected; then
        local current_check
        current_check=$(dexter_warp_get_ip_and_country)
        if [ -n "$current_check" ]; then
            local current_country="${current_check##*|}"
            if [ "$current_country" = "$target" ]; then
                printf "%b\n" "${GREEN}✔ Already connected to a ${target} exit.${NC}"
                printf "%b\n" "IP       : ${GREEN}${current_check%%|*}${NC}"
                rm -f "$lkg_conf_backup" 2>/dev/null
                return 0
            fi
        fi
    fi

    printf "%b\n" "${CYAN}Searching for a $target exit (up to ${max_attempts} attempts / $((max_seconds/60))min)...${NC}"

    # NOTE: previously this pre-filtered via get_healthy_endpoints() using a
    # broken TCP probe against UDP-only WireGuard endpoints (see the
    # optimize function's comment for the full explanation) -- removed in
    # favor of just using the real list and letting the actual connect+
    # trace attempt below be the ground-truth test.
    local -a endpoints_array=("${WARP_ENDPOINTS[@]}")

    # Try each known endpoint once, in a random (shuffled) order rather
    # than picking with replacement -- with only a handful of fixed PoPs,
    # each one deterministically leads to roughly the same colo/country
    # every time, so randomly re-picking the same endpoint multiple times
    # (as the old "pick a random index every attempt" approach did) just
    # burns attempts without ever seeing a country the first pass hadn't
    # already revealed. One shuffled pass through every endpoint is both
    # faster and strictly more thorough than 50 random draws with
    # replacement from the same small pool.
    local -a shuffled=("${endpoints_array[@]}")
    local si sj tmp
    for ((si = ${#shuffled[@]} - 1; si > 0; si--)); do
        sj=$(( $(get_random) % (si + 1) ))
        tmp="${shuffled[$si]}"
        shuffled[$si]="${shuffled[$sj]}"
        shuffled[$sj]="$tmp"
    done
    if [ "${#shuffled[@]}" -lt "$max_attempts" ]; then
        max_attempts=${#shuffled[@]}
    fi

    local start_ts
    start_ts=$(date +%s)
    local attempt=0
    local found=false
    local final_ip="" final_country="" final_endpoint=""
    local last_ip="" last_country=""

    _live_block_start
    while [ "$attempt" -lt "$max_attempts" ]; do
        local now_ts elapsed
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        [ "$elapsed" -ge "$max_seconds" ] && break
        attempt=$((attempt + 1))

        dexter_warp_disconnect

        local selected_endpoint validated_ep
        selected_endpoint="${shuffled[$((attempt - 1))]}"
        validated_ep=$(validate_endpoint "$selected_endpoint")
        [ -z "$validated_ep" ] && { log_msg "WARNING" "Invalid endpoint skipped: $selected_endpoint"; continue; }

        WG_PEER_ENDPOINT="$validated_ep"
        save_config
        dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
        _service_start
        wait_for_port "$SOCKS5_PORT" 8 0.5
        sleep 1

        local result
        result=$(dexter_warp_get_ip_and_country)
        last_ip="${result%%|*}"
        last_country="${result##*|}"

        _live_block_update \
            "${CYAN}Searching for: ${target}${NC}" \
            "Attempt  : ${attempt}/${max_attempts}" \
            "Current  : ${last_country:-??}" \
            "IP       : ${last_ip:-N/A}" \
            "Elapsed  : $(fmt_mmss "$elapsed")"

        if [ -n "$last_country" ] && [ "$last_country" = "$target" ]; then
            # Don't trust a single reading right after the port opens --
            # the SOCKS5 port can start accepting connections slightly
            # before the WireGuard handshake to the new peer has fully
            # settled, so the very first trace request can occasionally
            # still ride on leftover/incomplete routing state and report
            # something that doesn't match what the connection actually
            # settles on a moment later. Wait briefly, force a fresh
            # (non-cached) re-check, and only declare success if the
            # second reading still agrees.
            invalidate_cache
            sleep 1.5
            local recheck recheck_ip recheck_country
            recheck=$(dexter_warp_get_ip_and_country)
            recheck_ip="${recheck%%|*}"
            recheck_country="${recheck##*|}"
            if [ -n "$recheck_country" ] && [ "$recheck_country" = "$target" ]; then
                found=true
                final_ip="${recheck_ip:-$last_ip}"
                final_country="$recheck_country"
                final_endpoint="$validated_ep"
                break
            else
                _live_block_update \
                    "${CYAN}Searching for: ${target}${NC}" \
                    "Attempt  : ${attempt}/${max_attempts}" \
                    "Current  : ${last_country} -> unstable, re-checked as ${recheck_country:-??}, retrying" \
                    "IP       : ${recheck_ip:-N/A}" \
                    "Elapsed  : $(fmt_mmss "$elapsed")"
            fi
        fi
    done
    _live_block_end

    local total_elapsed=$(( $(date +%s) - start_ts ))

    if [ "$found" = true ]; then
        printf "%b\n" "${GREEN}✔ Country found${NC}"
        printf "%b\n" ""
        printf "%b\n" "Country  : ${GREEN}${final_country}${NC}"
        printf "%b\n" "IP       : ${GREEN}${final_ip}${NC}"
        printf "%b\n" "Attempts : ${attempt}"
        printf "%b\n" "Time     : ${total_elapsed}s"
        printf "%b\n" "Endpoint : ${final_endpoint}"
        write_cache "$final_ip" "$final_country"
        log_msg "INFO" "Change IP by country success: $target reached at $final_ip via $final_endpoint after $attempt attempts"
        rm -f "$lkg_conf_backup" 2>/dev/null
        return 0
    fi

    printf "%b\n" "${YELLOW}✗ Country not found after ${attempt} attempts (${total_elapsed}s).${NC}"
    printf "%b\n" "${YELLOW}Note: only the ${#WARP_ENDPOINTS[@]} known Cloudflare PoPs in this script's endpoint list were tried - ${NC}"
    printf "%b\n" "${YELLOW}some countries may simply not be reachable through any of them.${NC}"
    printf "%b\n" "${CYAN}Restoring previous working configuration...${NC}"

    WG_PEER_ENDPOINT="$lkg_endpoint"
    save_config
    if [ -s "$lkg_conf_backup" ]; then
        dexter_warp_disconnect
        cp -f "$lkg_conf_backup" "$WIREPROXY_CONF" 2>/dev/null
        chmod 600 "$WIREPROXY_CONF" 2>/dev/null
    else
        dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
    fi
    _service_start
    wait_for_port "$SOCKS5_PORT" 10 0.5
    rm -f "$lkg_conf_backup" 2>/dev/null
    printf "%b\n" "${GREEN}Done.${NC}"
    log_msg "WARNING" "Change IP by country: target $target not reached after $attempt attempts; restored previous config"
    return 2
}

# ==========================================
# Section 21d: Optimize Connection (Best PoP by score)
# ==========================================
# WARP isn't designed to be a "pick your country" VPN - what actually
# determines quality is which Cloudflare PoP/colo you land on relative to
# the server's own location, not the country label. A DE server exiting
# through AMS can be excellent; the same server exiting through a distant
# PoP under a "matching-sounding" country can be much worse. This tests
# every known-healthy endpoint ONCE per run (not up to 50 retries like the
# country search) and scores each on three independent signals instead of
# a single latency number:
#   - setup_ms  : time from launching wireproxy with this endpoint until
#                 the SOCKS5 port is actually listening (process start +
#                 WireGuard handshake + readiness - a real "how long until
#                 usable" number, distinct from steady-state RTT)
#   - avg_ms    : average of 3 cdn-cgi/trace round-trips once connected
#   - jitter_ms : (max-min) spread across those 3 samples, as a cheap
#                 stability signal - a fast-but-erratic endpoint (e.g. one
#                 sample fine, next one a big spike) is worse in practice
#                 than a slightly slower but consistent one, even though a
#                 single-sample latency check would never show that.
#
# SCORING: score = 1000 - avg_ms - (jitter_ms * 3) - (setup_ms / 5)
# Higher is better. The exact weights (jitter weighted 3x, setup divided
# by 5) are a reasonable heuristic, not a scientifically tuned formula -
# they're deliberately kept as plain named constants below so they're easy
# to retune later if real-world results suggest different weighting.
#
# Deliberately NOT included: real throughput/Mbps testing. Measuring
# actual download speed per endpoint means pulling a real multi-MB file
# from each of them, which is slow, burns bandwidth on every run, and is
# noisy (varies minute to minute) - not worth the cost for a "which PoP is
# best" check. A deeper throughput-based mode can be added later if this
# heuristic turns out to be insufficient in practice.
_OPT_JITTER_WEIGHT=3
_OPT_SETUP_DIVISOR=5

dexter_warp_optimize_connection() {
    local non_interactive="${1:-}"
    # When "different" is passed, the final selection skips any result
    # whose country matches wherever we're already connected, so the user
    # is guaranteed to land somewhere new rather than possibly being
    # re-scored back onto the exact same exit they started from.
    local exclude_current="${2:-}"

    if ! dexter_warp_is_installed; then
        printf "%b\n" "${RED}WARP is not installed.${NC}"
        return 1
    fi
    if ! check_internet; then
        printf "%b\n" "${RED}No internet connection.${NC}"
        return 1
    fi

    local current_country_before=""
    if [ "$exclude_current" = "different" ] && dexter_warp_is_connected; then
        local current_check
        current_check=$(dexter_warp_get_ip_and_country)
        [ -n "$current_check" ] && current_country_before="${current_check##*|}"
    fi

    local lkg_endpoint="$WG_PEER_ENDPOINT"
    local lkg_conf_backup
    lkg_conf_backup=$(mktemp 2>/dev/null) || lkg_conf_backup="${WIREPROXY_CONF}.lkg.$$"
    cp -f "$WIREPROXY_CONF" "$lkg_conf_backup" 2>/dev/null

    # NOTE: previously this pre-filtered via get_healthy_endpoints(), which
    # used a TCP probe ("nc -z") to guess reachability. WireGuard/WARP only
    # ever answers on UDP -- a TCP probe against it is testing the wrong
    # protocol entirely, so it produced unreliable results (sometimes
    # correctly falling back to all 7 endpoints, sometimes appearing to
    # find only 1 "healthy" one for reasons unrelated to real WARP
    # reachability). The real test below -- actually connecting through
    # each endpoint and requesting cdn-cgi/trace -- is already the
    # ground-truth reachability check, so the TCP pre-filter added no
    # value and only introduced a source of false negatives. Just use the
    # full list directly.
    local -a endpoints_array=("${WARP_ENDPOINTS[@]}")

    printf "%b\n" "${CYAN}Testing ${#endpoints_array[@]} endpoints (3 samples each)...${NC}"

    local -a result_ep=() result_colo=() result_country=() result_avg=() result_jitter=() result_setup=() result_score=()
    local idx=0
    local total=${#endpoints_array[@]}

    [ "$non_interactive" != "quiet" ] && _live_block_start
    local ep
    for ep in "${endpoints_array[@]}"; do
        idx=$((idx + 1))
        local validated_ep
        validated_ep=$(validate_endpoint "$ep")
        [ -z "$validated_ep" ] && continue

        dexter_warp_disconnect
        WG_PEER_ENDPOINT="$validated_ep"
        save_config
        dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"

        local t_setup_start t_setup_end setup_ms
        t_setup_start=$(date +%s%N)
        _service_start
        wait_for_port "$SOCKS5_PORT" 8 0.5
        t_setup_end=$(date +%s%N)
        setup_ms=$(( (t_setup_end - t_setup_start) / 1000000 ))

        [ "$non_interactive" != "quiet" ] && _live_block_update \
            "${CYAN}Optimizing WARP exit...${NC}" \
            "Testing  : ${idx}/${total} (${validated_ep})" \
            "Setup    : ${setup_ms}ms" \
            "Sampling : 0/3"

        # 3 real round-trips through the now-connected tunnel, each one
        # also gives colo/country (kept from the last successful sample).
        local -a samples=()
        local colo="" country="" sample_idx
        for sample_idx in 1 2 3; do
            local t_start t_end trace ms
            t_start=$(date +%s%N)
            trace=$(HTTP_CONNECT_TIMEOUT=4 HTTP_MAX_TIME=8 HTTP_RETRY=0 \
                http_get "https://www.cloudflare.com/cdn-cgi/trace" --socks5-hostname "${PROXY_IP}:${SOCKS5_PORT}" 2>/dev/null)
            t_end=$(date +%s%N)
            if [ -n "$trace" ]; then
                ms=$(( (t_end - t_start) / 1000000 ))
                samples+=("$ms")
                while IFS='=' read -r k v; do
                    v="${v%$'\r'}"
                    [ "$k" = "colo" ] && colo="$v"
                    [ "$k" = "loc" ] && country="$v"
                done <<< "$trace"
                [ "$non_interactive" != "quiet" ] && _live_block_update \
                    "${CYAN}Optimizing WARP exit...${NC}" \
                    "Testing  : ${idx}/${total} (${validated_ep})" \
                    "Setup    : ${setup_ms}ms  |  Colo: ${colo:-??}  Country: ${country:-??}" \
                    "Sampling : ${sample_idx}/3 (${ms}ms)"
            fi
        done

        if [ ${#samples[@]} -eq 0 ]; then
            [ "$non_interactive" != "quiet" ] && _live_block_update \
                "${CYAN}Optimizing WARP exit...${NC}" \
                "Testing  : ${idx}/${total} (${validated_ep})" \
                "Result   : unreachable" \
                "Sampling : 0/3"
            sleep 0.2
            continue
        fi

        local sum=0 min="${samples[0]}" max="${samples[0]}" s
        for s in "${samples[@]}"; do
            sum=$((sum + s))
            [ "$s" -lt "$min" ] && min="$s"
            [ "$s" -gt "$max" ] && max="$s"
        done
        local avg_ms=$((sum / ${#samples[@]}))
        local jitter_ms=$((max - min))
        local score=$(( 1000 - avg_ms - (jitter_ms * _OPT_JITTER_WEIGHT) - (setup_ms / _OPT_SETUP_DIVISOR) ))

        result_ep+=("$validated_ep")
        result_colo+=("${colo:-??}")
        result_country+=("${country:-??}")
        result_avg+=("$avg_ms")
        result_jitter+=("$jitter_ms")
        result_setup+=("$setup_ms")
        result_score+=("$score")

        [ "$non_interactive" != "quiet" ] && _live_block_update \
            "${CYAN}Optimizing WARP exit...${NC}" \
            "Testing  : ${idx}/${total} (${validated_ep})" \
            "Result   : ${colo:-??} / ${country:-??}  avg=${avg_ms}ms  jitter=${jitter_ms}ms" \
            "Setup    : ${setup_ms}ms"
        sleep 0.2
    done
    [ "$non_interactive" != "quiet" ] && _live_block_end

    if [ ${#result_ep[@]} -eq 0 ]; then
        printf "%b\n" "${RED}No endpoint responded. Restoring previous configuration.${NC}"
        WG_PEER_ENDPOINT="$lkg_endpoint"
        save_config
        dexter_warp_disconnect
        [ -s "$lkg_conf_backup" ] && cp -f "$lkg_conf_backup" "$WIREPROXY_CONF" 2>/dev/null
        chmod 600 "$WIREPROXY_CONF" 2>/dev/null
        _service_start
        wait_for_port "$SOCKS5_PORT" 10 0.5
        rm -f "$lkg_conf_backup" 2>/dev/null
        return 1
    fi

    # Rank by score descending (higher = better).
    printf "%b\n" ""
    printf "%b\n" "${CYAN}Results (best score first):${NC}"
    local -a order
    order=($(for i in "${!result_score[@]}"; do printf '%s\t%s\n' "${result_score[$i]}" "$i"; done | sort -rn | cut -f2))
    local rank=1
    for i in "${order[@]}"; do
        local mark=" "
        [ "$rank" -eq 1 ] && mark="★"
        printf "%b\n" "  ${mark} ${result_colo[$i]} (${result_country[$i]})  avg=${result_avg[$i]}ms  jitter=${result_jitter[$i]}ms  setup=${result_setup[$i]}ms  score=${result_score[$i]}  (${result_ep[$i]})"
        rank=$((rank + 1))
    done

    local best_idx="${order[0]}"
    local skipped_for_same_country=false
    if [ "$exclude_current" = "different" ] && [ -n "$current_country_before" ]; then
        local found_different=false
        for i in "${order[@]}"; do
            if [ "${result_country[$i]}" != "$current_country_before" ]; then
                best_idx="$i"
                found_different=true
                break
            fi
        done
        if [ "$found_different" = false ]; then
            # Every reachable endpoint landed in the same country as
            # before (e.g. only one PoP is actually usable from this
            # network) -- fall back to the plain best rather than
            # refusing outright, but say so honestly.
            skipped_for_same_country=true
            best_idx="${order[0]}"
        fi
    fi

    local best_ep="${result_ep[$best_idx]}"
    local best_colo="${result_colo[$best_idx]}"
    local best_country="${result_country[$best_idx]}"
    local best_avg="${result_avg[$best_idx]}"
    local best_score="${result_score[$best_idx]}"

    printf "%b\n" ""
    if [ "$exclude_current" = "different" ]; then
        if [ "$skipped_for_same_country" = true ]; then
            printf "%b\n" "${YELLOW}Every reachable endpoint landed in ${current_country_before} - couldn't find a different country from here. Using the best overall instead:${NC}"
        else
            printf "%b\n" "${GREEN}Best Exit different from current (${current_country_before:-current}): ${best_colo} (${best_country}), avg ${best_avg}ms, score ${best_score} - applying...${NC}"
        fi
    fi
    [ "$exclude_current" != "different" ] && printf "%b\n" "${GREEN}Best Exit: ${best_colo} (${best_country}), avg ${best_avg}ms, score ${best_score} - applying...${NC}"

    dexter_warp_disconnect
    WG_PEER_ENDPOINT="$best_ep"
    save_config
    dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
    _service_start
    wait_for_port "$SOCKS5_PORT" 10 0.5

    local final_ip
    final_ip=$(dexter_warp_get_out_ip)
    [ -n "$final_ip" ] && write_cache "$final_ip" "$best_country"
    printf "%b\n" ""
    printf "%b\n" "Exit PoP : ${best_colo}"
    printf "%b\n" "Country  : ${best_country}"
    printf "%b\n" "IP       : ${final_ip:-N/A}"
    printf "%b\n" "${GREEN}✔ Applied.${NC}"
    log_msg "INFO" "Optimize connection: selected $best_ep (colo=$best_colo, country=$best_country, avg=${best_avg}ms, score=$best_score) out of ${#result_ep[@]} tested"
    rm -f "$lkg_conf_backup" 2>/dev/null
    return 0
}

# Small submenu so the rarely-needed "full re-registration" recovery tool
# (previously the standalone "New Identity" menu item) and the new
# optimizer stay reachable without cluttering the main menu with several
# confusingly-similar "change IP" options.
# ==========================================
# Section 21e: Optimize to a different country (retry-based)
# ==========================================
# The plain optimizer tests each of the ~7 known endpoints exactly once,
# which is fast but has a real limitation: these are Cloudflare anycast
# IPs, and the same fixed IP does not always land on the same physical
# PoP/colo on every connection attempt (anycast routing can shift with
# network conditions, load, or just time). One deterministic pass can
# easily land on the current country repeatedly for several of the 7
# endpoints and never discover the variance available from re-trying the
# same IPs. This function instead retries (drawing endpoints at random,
# repeats allowed) up to a fixed attempt/time budget specifically hunting
# for ANY exit whose country differs from wherever we started, collecting
# a small pool of genuinely-different candidates and picking the fastest
# of those rather than stopping at the very first different one found.
dexter_warp_optimize_different_country() {
    if ! dexter_warp_is_installed; then
        printf "%b\n" "${RED}WARP is not installed.${NC}"
        return 1
    fi
    if ! check_internet; then
        printf "%b\n" "${RED}No internet connection.${NC}"
        return 1
    fi

    local current_country=""
    if dexter_warp_is_connected; then
        local current_check
        current_check=$(dexter_warp_get_ip_and_country)
        [ -n "$current_check" ] && current_country="${current_check##*|}"
    fi

    local lkg_endpoint="$WG_PEER_ENDPOINT"
    local lkg_conf_backup
    lkg_conf_backup=$(mktemp 2>/dev/null) || lkg_conf_backup="${WIREPROXY_CONF}.lkg.$$"
    cp -f "$WIREPROXY_CONF" "$lkg_conf_backup" 2>/dev/null

    local max_attempts=30
    local max_seconds=240
    # Stop early once this many genuinely-different candidates are found,
    # rather than always burning the full 30 attempts once we already have
    # enough to pick a good one from.
    local candidate_goal=4

    printf "%b\n" "${CYAN}Searching up to ${max_attempts} attempts for an exit outside ${current_country:-your current country}...${NC}"

    local -a cand_ep=() cand_ip=() cand_country=() cand_colo=() cand_ms=()
    local start_ts attempt=0
    start_ts=$(date +%s)

    _live_block_start
    while [ "$attempt" -lt "$max_attempts" ] && [ "${#cand_ep[@]}" -lt "$candidate_goal" ]; do
        local now_ts elapsed
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        [ "$elapsed" -ge "$max_seconds" ] && break
        attempt=$((attempt + 1))

        local rand_val rand_idx selected_endpoint validated_ep
        rand_val=$(get_random)
        rand_idx=$((rand_val % ${#WARP_ENDPOINTS[@]}))
        selected_endpoint="${WARP_ENDPOINTS[$rand_idx]}"
        validated_ep=$(validate_endpoint "$selected_endpoint")
        [ -z "$validated_ep" ] && continue

        dexter_warp_disconnect
        WG_PEER_ENDPOINT="$validated_ep"
        save_config
        dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
        _service_start
        wait_for_port "$SOCKS5_PORT" 8 0.5

        local t_start t_end trace ms colo="" country=""
        t_start=$(date +%s%N)
        trace=$(HTTP_CONNECT_TIMEOUT=4 HTTP_MAX_TIME=8 HTTP_RETRY=0 \
            http_get "https://www.cloudflare.com/cdn-cgi/trace" --socks5-hostname "${PROXY_IP}:${SOCKS5_PORT}" 2>/dev/null)
        t_end=$(date +%s%N)
        local ip=""
        if [ -n "$trace" ]; then
            ms=$(( (t_end - t_start) / 1000000 ))
            while IFS='=' read -r k v; do
                v="${v%$'\r'}"
                case "$k" in
                    colo) colo="$v" ;;
                    loc) country="$v" ;;
                    ip) ip="$v" ;;
                esac
            done <<< "$trace"
        fi

        _live_block_update \
            "${CYAN}Searching for a different exit...${NC}" \
            "Attempt    : ${attempt}/${max_attempts}" \
            "Candidates : ${#cand_ep[@]}/${candidate_goal}" \
            "Last try   : ${colo:-??} / ${country:-??}  ${ms:-?}ms" \
            "Elapsed    : $(fmt_mmss "$elapsed")"

        if [ -n "$country" ] && [ "$country" != "$current_country" ] && [ -n "$ip" ]; then
            cand_ep+=("$validated_ep")
            cand_ip+=("$ip")
            cand_country+=("$country")
            cand_colo+=("${colo:-??}")
            cand_ms+=("$ms")
        fi
    done
    _live_block_end

    if [ "${#cand_ep[@]}" -eq 0 ]; then
        printf "%b\n" "${YELLOW}✗ Never landed outside ${current_country:-the current country} after ${attempt} attempts. Restoring previous configuration.${NC}"
        WG_PEER_ENDPOINT="$lkg_endpoint"
        save_config
        dexter_warp_disconnect
        [ -s "$lkg_conf_backup" ] && cp -f "$lkg_conf_backup" "$WIREPROXY_CONF" 2>/dev/null
        chmod 600 "$WIREPROXY_CONF" 2>/dev/null
        _service_start
        wait_for_port "$SOCKS5_PORT" 10 0.5
        rm -f "$lkg_conf_backup" 2>/dev/null
        return 1
    fi

    # Pick the fastest candidate among the different-country pool found.
    local best_i=0 i
    for i in "${!cand_ms[@]}"; do
        [ "${cand_ms[$i]}" -lt "${cand_ms[$best_i]}" ] && best_i="$i"
    done

    # Re-confirm before committing, same reasoning as the by-country
    # search: don't trust a single reading, make sure it's stable.
    WG_PEER_ENDPOINT="${cand_ep[$best_i]}"
    save_config
    dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
    dexter_warp_disconnect
    _service_start
    wait_for_port "$SOCKS5_PORT" 8 0.5
    invalidate_cache
    sleep 1.5
    local recheck recheck_ip recheck_country
    recheck=$(dexter_warp_get_ip_and_country)
    recheck_ip="${recheck%%|*}"
    recheck_country="${recheck##*|}"

    if [ -z "$recheck_country" ] || [ "$recheck_country" = "$current_country" ]; then
        printf "%b\n" "${YELLOW}Selection was unstable on re-check. Restoring previous configuration.${NC}"
        WG_PEER_ENDPOINT="$lkg_endpoint"
        save_config
        dexter_warp_disconnect
        [ -s "$lkg_conf_backup" ] && cp -f "$lkg_conf_backup" "$WIREPROXY_CONF" 2>/dev/null
        chmod 600 "$WIREPROXY_CONF" 2>/dev/null
        _service_start
        wait_for_port "$SOCKS5_PORT" 10 0.5
        rm -f "$lkg_conf_backup" 2>/dev/null
        return 1
    fi

    printf "%b\n" ""
    printf "%b\n" "${GREEN}✔ Found a different exit${NC}"
    printf "%b\n" "From     : ${current_country:-Unknown}"
    printf "%b\n" "To       : ${GREEN}${recheck_country}${NC} (colo ${cand_colo[$best_i]})"
    printf "%b\n" "IP       : ${GREEN}${recheck_ip}${NC}"
    printf "%b\n" "Attempts : ${attempt}  (from ${#cand_ep[@]} different-country candidates found)"
    write_cache "$recheck_ip" "$recheck_country"
    log_msg "INFO" "Optimize-different: moved from ${current_country:-?} to ${recheck_country} at ${recheck_ip} via ${cand_ep[$best_i]}"
    rm -f "$lkg_conf_backup" 2>/dev/null
    return 0
}

dexter_warp_change_ip_menu() {
    printf "%b\n" "${CYAN}--- Change IP ---${NC}"
    printf "%b\n" "  1) Optimize (Best Latency/PoP) - recommended"
    printf "%b\n" "  2) By Country (manual)"
    printf "%b\n" "  3) Generate New WARP Identity (full re-registration - use if the account/registration itself seems broken)"
    printf "%b\n" "  0) Cancel"
    local choice
    read -r -p "Choose option: " choice
    case "$choice" in
        1) dexter_warp_optimize_different_country ;;
        2) dexter_warp_change_ip_by_country ;;
        3) dexter_warp_new_identity ;;
        *) printf "%b\n" "${YELLOW}Canceled.${NC}" ;;
    esac
}

# ==========================================
dexter_warp_change_port() {
    local new_port new_ip
    echo -ne "${YELLOW}Enter new SOCKS5 port (1024-65535) [Current: $SOCKS5_PORT]: ${NC}"
    read -r new_port

    [ -z "$new_port" ] && new_port="$SOCKS5_PORT"

    if ! validate_port "$new_port"; then
        printf "%b\n" "${RED}[ERROR] Port must be numeric between 1024 and 65535.${NC}"
        return 1
    fi

    echo -ne "${YELLOW}Enter SOCKS5 Bind IP [Current: $PROXY_IP]: ${NC}"
    read -r new_ip
    [ -z "$new_ip" ] && new_ip="$PROXY_IP"

    if ! validate_ip "$new_ip"; then
        printf "%b\n" "${RED}[ERROR] Invalid IP format.${NC}"
        return 1
    fi

    printf "%b\n" "${CYAN}Stopping WARP to verify port availability...${NC}"
    local was_connected=false
    if dexter_warp_is_connected; then
        was_connected=true
        dexter_warp_disconnect
    fi

    if port_in_use "$new_port"; then
        printf "%b\n" "${RED}[ERROR] Port $new_port is already in use.${NC}"
        if [ "$was_connected" = true ]; then
            printf "%b\n" "${YELLOW}Restoring previous connection...${NC}"
            dexter_warp_connect
        fi
        return 1
    fi

    SOCKS5_PORT="$new_port"
    PROXY_IP="$new_ip"
    save_config

    if [ -n "$WG_PRIV_KEY" ]; then
        dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
    fi

    # dexter_warp_connect() already performs full verification of the new
    # port internally: wait_for_port (listening check) followed by
    # dexter_warp_verify_wireproxy_connection, which does a real SOCKS5
    # traffic check against ${PROXY_IP}:${SOCKS5_PORT} with several
    # retries and even triggers self-healing if needed. Re-checking here
    # with a second, separate loop was strictly weaker: a single cf_trace
    # call can itself take close to the curl timeout (~5s), so the old
    # 15-iteration/0.5s-sleep loop (nominally 7.5s) often only got through
    # 1-2 real attempts before giving up -- producing a false "verification
    # timed out" warning even when dexter_warp_connect had already
    # confirmed the tunnel was working. Trust its result directly instead.
    if dexter_warp_connect; then
        printf "%b\n" "${GREEN}[✓] SOCKS5 port changed to $PROXY_IP:$SOCKS5_PORT.${NC}"
        log_msg "INFO" "SOCKS5 port changed to $PROXY_IP:$SOCKS5_PORT"
    else
        printf "%b\n" "${RED}[WARNING] Port changed but connection verification failed. Check logs (option 9) for details.${NC}"
        log_msg "WARNING" "SOCKS5 port changed but verify failed"
    fi
}

dexter_warp_get_mode_label() {
    case "$IP_VERSION" in
        4)     echo "IPv4 Only (Recommended)" ;;
        dual)  echo "Dual Stack (IPv4+IPv6)" ;;
        6)     echo "IPv6 Only" ;;
        *)     echo "IPv4 Only" ;;
    esac
}

dexter_warp_get_run_mode_label() {
    case "$RUN_MODE" in
        VPS)       echo "VPS Mode (Full Services)" ;;
        Container) echo "Container Mode (No-Root Fallbacks)" ;;
        Minimal)   echo "Minimal Mode (Lightweight CLI)" ;;
        *)         echo "VPS Mode" ;;
    esac
}

# Short form used inside the boxed menu line, where the full descriptive
# label (with its parenthetical) is too wide and pushes past the box's
# right border. The full label above is still used in submenus and
# confirmation messages where there's no fixed-width box to respect.
dexter_warp_get_run_mode_short_label() {
    case "$RUN_MODE" in
        VPS)       echo "VPS Mode" ;;
        Container) echo "Container Mode" ;;
        Minimal)   echo "Minimal Mode" ;;
        *)         echo "VPS Mode" ;;
    esac
}

dexter_warp_apply_ip_mode_changes() {
    if dexter_warp_is_installed; then
        if [ -n "$WG_PRIV_KEY" ]; then
            dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
            if dexter_warp_is_connected; then
                dexter_warp_restart
            fi
        fi
    fi
}

dexter_warp_switch_run_mode() {
    local rm_choice=""
    printf "%b\n" "${CYAN}--- Switch Script Portability Mode ---${NC}"
    printf "%b\n" "Current: ${GREEN}$(dexter_warp_get_run_mode_label)${NC}"
    printf "%b\n" "  1) VPS Mode (Systemd/OpenRC)"
    printf "%b\n" "  2) Container Mode (nohup, fallback paths)"
    printf "%b\n" "  3) Minimal Mode (Lightweight CLI)"
    printf "%b\n" "  0) Cancel"
    echo -ne "${YELLOW}Choose Option: ${NC}"
    read -r rm_choice
    case "$rm_choice" in
        1) RUN_MODE="VPS" ;;
        2) RUN_MODE="Container" ;;
        3) RUN_MODE="Minimal" ;;
        *) printf "%b\n" "${YELLOW}Canceled.${NC}"; return ;;
    esac
    save_config
    CURRENT_MODE="$RUN_MODE"
    init_paths
    load_config
    _ensure_dirs
    printf "%b\n" "${GREEN}[✓] Switched to $(dexter_warp_get_run_mode_label).${NC}"
}

dexter_warp_switch_ip_mode() {
    local ip_choice=""
    printf "%b\n" "${CYAN}--- Switch IP Version Mode ---${NC}"
    printf "%b\n" "Current: ${GREEN}$(dexter_warp_get_mode_label)${NC}"
    printf "%b\n" "  1) IPv4 Only (Recommended)"
    printf "%b\n" "  2) Dual Stack (IPv4 + IPv6)"
    printf "%b\n" "  3) IPv6 Only"
    printf "%b\n" "  0) Cancel"

    if check_ipv6_available; then
        printf "%b\n" "${GREEN}  IPv6 Status: Available${NC}"
    else
        printf "%b\n" "${RED}  IPv6 Status: Not Available on this system${NC}"
    fi
    printf "%b\n" "${YELLOW}Note: IPv6 can be unstable on some Iranian ISPs.${NC}"
    echo -ne "${YELLOW}Choose Option: ${NC}"
    read -r ip_choice

    case "$ip_choice" in
        1) IP_VERSION="4" ;;
        2)
            if ! check_ipv6_available; then
                printf "%b\n" "${YELLOW}[WARNING] IPv6 connectivity test failed on this system. Dual Stack will still work over IPv4, but the IPv6 leg likely won't.${NC}"
                read -r -p "Continue with Dual Stack anyway? [y/N]: " confirm_dual
                [[ ! "$confirm_dual" =~ ^[Yy]$ ]] && { printf "%b\n" "${YELLOW}Canceled.${NC}"; return; }
            fi
            IP_VERSION="dual" ;;
        3)
            if ! check_ipv6_available; then
                printf "%b\n" "${RED}[ERROR] IPv6 outbound connectivity test failed on this system (interface may exist but not actually reach the internet). Cannot switch to IPv6-only mode.${NC}"
                return 1
            fi
            IP_VERSION="6" ;;
        *) printf "%b\n" "${YELLOW}Canceled.${NC}"; return ;;
    esac
    save_config
    printf "%b\n" "${GREEN}[✓] Switched to $(dexter_warp_get_mode_label).${NC}"
    dexter_warp_apply_ip_mode_changes
}

dexter_warp_backup_restore() {
    local backup_path
    backup_path="$(get_config_path).bak"
    local wire_backup_path
    wire_backup_path="$(get_wireproxy_conf_path).bak"

    printf "%b\n" "${CYAN}--- Backup / Restore ---${NC}"
    printf "%b\n" "  1) Backup Current Configuration"
    printf "%b\n" "  2) Restore from Backup"
    printf "%b\n" "  0) Cancel"
    echo -ne "${YELLOW}Select: ${NC}"
    read -r br_choice

    if [ "$br_choice" = "1" ]; then
        cp "$(get_config_path)" "$backup_path" 2>/dev/null || true
        cp "$(get_wireproxy_conf_path)" "$wire_backup_path" 2>/dev/null || true
        chmod 600 "$backup_path" 2>/dev/null || true
        chmod 600 "$wire_backup_path" 2>/dev/null || true
        printf "%b\n" "${GREEN}[✓] Backup created at ${backup_path}.${NC}"
        log_msg "INFO" "Backup created"
    elif [ "$br_choice" = "2" ]; then
        if [ -f "$backup_path" ]; then
            cp "$backup_path" "$(get_config_path)" 2>/dev/null
            chmod 600 "$(get_config_path)" 2>/dev/null || true
            if [ -f "$wire_backup_path" ]; then
                cp "$wire_backup_path" "$(get_wireproxy_conf_path)" 2>/dev/null
                chmod 600 "$(get_wireproxy_conf_path)" 2>/dev/null || true
            fi
            printf "%b\n" "${GREEN}[✓] Restored. Restarting...${NC}"
            log_msg "INFO" "Configuration restored from backup"
            dexter_warp_restart
        else
            printf "%b\n" "${RED}[ERROR] No backup found.${NC}"
        fi
    fi
}

dexter_warp_reset_config() {
    read -r -p "Reset configurations to defaults? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        dexter_warp_disconnect
        rm -f "$(get_config_path)" 2>/dev/null
        rm -f "$(get_wireproxy_conf_path)" 2>/dev/null
        rm -f "$(get_cache_path)" 2>/dev/null
        SOCKS5_PORT="$DEFAULT_SOCKS5_PORT"
        PROXY_IP="$DEFAULT_PROXY_IP"
        IP_VERSION="4"
        WG_PRIV_KEY=""
        WG_PEER_PUB_KEY=""
        WG_PEER_ENDPOINT=""
        WG_IPV4=""
        WG_IPV6=""
        WG_REG_ID=""
        WG_REG_TOKEN=""
        save_config
        printf "%b\n" "${GREEN}[✓] Configurations reset.${NC}"
    else
        printf "%b\n" "${YELLOW}Reset canceled.${NC}"
    fi
}

dexter_warp_remove() {
    printf "%b\n" "${RED}Removing WARP...${NC}"
    local wbin wconf cpath pid_file
    wbin=$(get_wireproxy_bin_path)
    wconf=$(get_wireproxy_conf_path)
    cpath=$(get_cache_path)
    pid_file=$(get_pid_path)

    if [ "$IS_ALPINE" = true ] && [ -f /etc/init.d/wireproxy ]; then
        rc-service wireproxy stop &>/dev/null || true
        rc-update del wireproxy default &>/dev/null || true
        rm -f /etc/init.d/wireproxy
    fi
    if [ -f /etc/systemd/system/wireproxy.service ]; then
        systemctl disable wireproxy &>/dev/null || true
        systemctl stop wireproxy &>/dev/null || true
        rm -f /etc/systemd/system/wireproxy.service
        systemctl daemon-reload &>/dev/null || true
    fi
    if [ -f "$pid_file" ]; then
        local pid=""
        read -r pid < "$pid_file" 2>/dev/null || pid=""
        [ -n "$pid" ] && safe_kill "$pid"
        rm -f "$pid_file" 2>/dev/null
    else
        pkill -x wireproxy 2>/dev/null || true
    fi
    rm -f "$wbin" "$wconf" "$(get_config_path)" "$cpath" 2>/dev/null
    rm -rf "$(dirname "$cpath")" 2>/dev/null
    printf "%b\n" "${GREEN}WireProxy files removed.${NC}"

    if [ "$IS_ALPINE" = true ]; then
        local del_dep=""
        read -r -p "Uninstall Alpine deps (wireguard-tools, jq, openssl)? [y/N]: " del_dep
        if [[ "$del_dep" =~ ^[Yy]$ ]]; then
            printf "%b\n" "${CYAN}Removing dependencies...${NC}"
            apk del jq wireguard-tools openssl 2>/dev/null || true
        fi
    else
        local del_apt=""
        read -r -p "Run apt autoremove? [y/N]: " del_apt
        if [[ "$del_apt" =~ ^[Yy]$ ]]; then
            apt-get autoremove -y 2>/dev/null || true
        fi
    fi
    log_msg "INFO" "Removed WireProxy completely"
}

# ==========================================
# Section 23: Update System
# ==========================================
dexter_warp_self_update() {
    printf "%b\n" "${CYAN}Checking for updates...${NC}"
    if ! check_internet; then
        printf "%b\n" "${RED}[ERROR] No internet. Update aborted.${NC}"
        return 1
    fi

    local remote_script_url="https://raw.githubusercontent.com/COD-DEXTER/WARP-DX/main/main.sh"
    local temp_file="/tmp/dexter-warp-update_$$.sh"

    if ! http_download "$remote_script_url" -o "$temp_file"; then
        printf "%b\n" "${RED}[ERROR] Failed to fetch update.${NC}"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    if ! verify_file_integrity "$temp_file"; then
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    if ! grep -q 'Created by: @COD-DEXTER' "$temp_file" 2>/dev/null; then
        printf "%b\n" "${RED}[ERROR] Security signature check failed.${NC}"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    local remote_hash
    remote_hash=$(http_get "https://raw.githubusercontent.com/COD-DEXTER/WARP-DX/main/main.sh.sha256" 2>/dev/null)
    remote_hash="${remote_hash%% *}"
    remote_hash="${remote_hash%%$'\n'}"
    remote_hash="${remote_hash%%$'\r'}"
    if [ -n "$remote_hash" ] && [ "$remote_hash" != "null" ]; then
        local actual_hash
        actual_hash=$(compute_sha256 "$temp_file")
        if [ -n "$actual_hash" ] && [ "$remote_hash" != "$actual_hash" ]; then
            printf "%b\n" "${RED}[ERROR] SHA256 mismatch. Update rejected.${NC}"
            printf "%b\n" "${RED}  Expected: ${remote_hash}${NC}"
            printf "%b\n" "${RED}  Got:      ${actual_hash}${NC}"
            rm -f "$temp_file" 2>/dev/null
            return 1
        fi
    fi

    if ! bash -n "$temp_file" 2>/dev/null; then
        printf "%b\n" "${RED}[ERROR] Downloaded script has syntax errors.${NC}"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    local remote_version
    remote_version=$(awk -F'"' '/^VERSION=/{print $2;exit}' "$temp_file" 2>/dev/null)

    if [ -z "$remote_version" ]; then
        printf "%b\n" "${RED}[ERROR] Could not parse remote version.${NC}"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    if ! version_gt "$remote_version" "$VERSION"; then
        printf "%b\n" "${GREEN}[✓] Already on latest version (v$VERSION).${NC}"
        rm -f "$temp_file" 2>/dev/null
        return 0
    fi

    printf "%b\n" "${YELLOW}New version: v$remote_version (Current: v$VERSION)${NC}"
    read -r -p "Update now? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local script_bin="$SCRIPT_PATH"
        local backup_script="${script_bin}.bak"
        [ -f "$script_bin" ] && cp "$script_bin" "$backup_script" 2>/dev/null || true

        # Atomic double-stage file replacement (fixes update race conditions)
        if cp "$temp_file" "${script_bin}.tmp" 2>/dev/null; then
            chmod +x "${script_bin}.tmp" 2>/dev/null
            if mv -f "${script_bin}.tmp" "$script_bin" 2>/dev/null; then
                rm -f "$temp_file" "$backup_script" 2>/dev/null
                printf "%b\n" "${GREEN}[✓] Update complete. Please restart.${NC}"
                log_msg "INFO" "Self update to v$remote_version succeeded"
                exit 0
            fi
        fi
        [ -f "$backup_script" ] && mv -f "$backup_script" "$script_bin" 2>/dev/null || true
        rm -f "$temp_file" 2>/dev/null
        printf "%b\n" "${RED}[ERROR] Update failed. Original preserved.${NC}"
        log_msg "ERROR" "Self update failed, rolled back to previous version"
        return 1
    else
        printf "%b\n" "${YELLOW}Update canceled.${NC}"
        rm -f "$temp_file" 2>/dev/null
    fi
}

dexter_warp_about() {
    printf "%b\n" "${CYAN}+----------------------------------------------------------------+${NC}"
    printf "%b\n" "|                       WARP DX v${VERSION}                             |"
    printf "%b\n" "|  A professional hybrid WARP client installer and SOCKS5 proxy  |"
    printf "%b\n" "|  manager supporting Ubuntu, Debian, Alpine Linux, and Docker.  |"
    printf "%b\n" "|                                                                |"
    printf "%b\n" "|  Created by: ${YELLOW}@COD-DEXTER${NC}                                       |"
    printf "%b\n" "+----------------------------------------------------------------+${NC}"
}

# ==========================================
# Section 24: Menu System
# ==========================================
dexter_warp_draw_menu() {
    if is_minimal; then
        printf "%b\n" "${CYAN}=== WARP DX v${VERSION} ===${NC}"
        if dexter_warp_is_connected; then
            printf "%b\n" "Status: ${GREEN}CONNECTED${NC} (${PROXY_IP}:${SOCKS5_PORT})"
        else
            printf "%b\n" "Status: ${RED}DISCONNECTED${NC}"
        fi
        printf "%b\n" "  1-Install  2-Status  3-Test  4-Remove  5-QuickIP"
        printf "%b\n" "  6-NewID  7-Port  8-Restart  9-Logs 10-Bkp/Rst"
        printf "%b\n" " 11-Reset 12-RunMode 13-IPMode 14-Update 15-About  0-Exit"
        printf "%b" "${YELLOW}> ${NC}"
        return 0
    fi

    # 'clear' relies on the terminfo database for $TERM; in minimal/Alpine
    # Docker images that database is often missing, so 'clear' silently
    # does nothing and new menu output just gets appended below the old
    # screen, looking like a "half old / half new" flash on redraw. Emit a
    # raw ANSI clear+home sequence as a guaranteed fallback alongside it.
    clear 2>/dev/null
    printf '\033[3J\033[H\033[2J'
    local is_connected="no"
    dexter_warp_is_connected && is_connected="yes"
    local socks5_ip="N/A"
    local socks5_country="Unknown"
    if [ "$is_connected" = "yes" ]; then
        local ip_country
        ip_country=$(dexter_warp_get_out_ip_and_country_cached 2>/dev/null)
        socks5_ip="${ip_country%%|*}"
        socks5_country="${ip_country##*|}"
        [ -z "$socks5_ip" ] && socks5_ip="N/A"
        [ -z "$socks5_country" ] && socks5_country="Unknown"
    fi

    print_line() {
        is_minimal && return 0
        local raw="$1"
        local clean
        if [ -n "$BASH_VERSION" ]; then
            local esc; esc=$(printf '\033')
            clean="$raw"
            while [[ "$clean" =~ ${esc}\[[^a-zA-Z]*[a-zA-Z] ]]; do
                clean="${clean//"${BASH_REMATCH[0]}"/}"
            done
        else
            clean=$(printf '%s' "$raw" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)
        fi
        local vislen=${#clean}
        local bw=73
        local inner=$((bw - vislen))
        [ "$inner" -lt 0 ] && inner=0
        printf "%b\n" "${CYAN}|${NC} ${raw}$(printf '%*s' "$inner" '')${CYAN}|${NC}"
    }

    local B="${CYAN}+---------------------------------------------------------+${NC}"
    local S="${CYAN}|${NC}"

    printf "%b\n" "$B"
    printf "%b\n" "${S} ${MAGENTA}██╗    ██╗ █████╗ ██████╗ ██████╗      ██████╗ ██╗  ██╗${NC} ${S}"
    printf "%b\n" "${S} ${YELLOW}██║    ██║██╔══██╗██╔══██╗██╔══██╗    ██╔══██╗╚██╗██╔╝${NC}  ${S}"
    printf "%b\n" "${S} ${YELLOW}██║ █╗ ██║███████║██████╔╝██████╔╝    ██║  ██║ ╚███╔╝${NC}   ${S}"         
    printf "%b\n" "${S} ${YELLOW}██║███╗██║██╔══██║██╔══██╗██╔═══╝     ██║  ██║ ██╔██╗${NC}   ${S}" 
    printf "%b\n" "${S} ${YELLOW}╚███╔███╔╝██║  ██║██║  ██║██║         ██████╔╝██╔╝ ██╗${NC}  ${S}"
    printf "%b\n" "${S} ${YELLOW} ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝         ╚═════╝ ╚═╝  ╚═╝${NC}  ${S}"
    printf "%b\n" "$B"

    printf "%b\n" "${S}  Creator: ${MAGENTA}@COD-DEXTER${NC}                     Version: ${GREEN}v${VERSION}${NC} ${S}"
    printf "%b\n" "$B"

    if [ "$is_connected" = "yes" ]; then
        print_line "WARP Status:   ${GREEN}CONNECTED${NC}"
        print_line "Proxy:         ${CYAN}${PROXY_IP}:${SOCKS5_PORT}${NC}"
        print_line "Out IP:        ${YELLOW}${socks5_ip}${NC}"
        print_line "Country:       ${YELLOW}${socks5_country}${NC}"
    else
        print_line "WARP Status:   ${RED}NOT CONNECTED${NC}"
    fi
    printf "%b\n" "$B"

    print_line  "${YELLOW}Choose an option :${NC}"
    printf "%b\n" "$B"
    print_line "  ${BLUE}1${NC}   Install WARP"
    print_line "  ${BLUE}2${NC}   Show Status"
    print_line "  ${BLUE}3${NC}   Test Proxy"
    print_line "  ${BLUE}4${NC}   Remove WARP"
    print_line "  ${BLUE}5${NC}   Change IP (Quick reconnect)"
    print_line "  ${BLUE}6${NC}   Change IP (Optimize / Country / New Identity)"
    print_line "  ${BLUE}7${NC}   Change SOCKS5 Port & Bind IP"
    print_line "  ${BLUE}8${NC}   Restart WARP"
    print_line "  ${BLUE}9${NC}   View Logs"
    print_line "  ${BLUE}10${NC}  Backup / Restore Config"
    print_line "  ${BLUE}11${NC}  Reset Configurations"
    print_line "  ${BLUE}12${NC}  Switch Run Mode  [$(dexter_warp_get_run_mode_short_label)]"
    print_line "  ${BLUE}13${NC}  Switch IP Mode   [$(dexter_warp_get_mode_label)]"
    print_line "  ${BLUE}14${NC}  Check For Update"
    print_line "  ${BLUE}15${NC}  About"
    print_line "  ${BLUE}0${NC}   Exit"
    printf "%b\n" "$B"
    printf "%b" "${YELLOW}  > ${NC}"
}

dexter_warp_main_menu() {
    # Verify OS Compatibility and setup flags on start
    if ! dexter_warp_check_os; then
        printf "%b\n" "${RED}[ERROR] Operating system is not supported.${NC}"
        exit 1
    fi

    while true; do
        dexter_warp_draw_menu
        read -r choice
        case "$choice" in
            1)  dexter_warp_install ;;
            2)  dexter_warp_status ;;
            3)  dexter_warp_test_proxy ;;
            4)  dexter_warp_remove ;;
            5)  dexter_warp_quick_change_ip ;;
            6)  dexter_warp_change_ip_menu ;;
            7)  dexter_warp_change_port ;;
            8)  dexter_warp_restart ;;
            9)  dexter_warp_view_logs ;;
            10) dexter_warp_backup_restore ;;
            11) dexter_warp_reset_config ;;
            12) dexter_warp_switch_run_mode ;;
            13) dexter_warp_switch_ip_mode ;;
            14) dexter_warp_self_update ;;
            15) dexter_warp_about ;;
            0) printf "%b\n" "${GREEN}Exiting...${NC}"; exit 0 ;;
            *) printf "%b\n" "${RED}Invalid choice. Try again.${NC}" ;;
        esac
        printf "%b\n" "\nPress Enter to return to menu..."
        read -r
    done
}

# ==========================================
# Section 25: Global Command Installer & CLI Dispatch
# ==========================================
# Copies this script to SCRIPT_PATH (e.g. /usr/local/bin/dexter-warp) and
# creates a short "warp" symlink next to it, so the tool is reachable the
# same way regardless of how it was first downloaded/run. Safe to run on
# every launch: it's a no-op once the script is already installed there.
_self_install_global_command() {
    [ -z "${SCRIPT_PATH:-}" ] && return 0

    local self_path target_real was_first_install=false
    self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

    # Repair a previous buggy install: if SCRIPT_PATH itself ended up as a
    # broken/self-referential symlink (a symlink pointing at its own path),
    # readlink -f cannot resolve it and it must be removed before we can
    # write a real file there again.
    if [ -L "$SCRIPT_PATH" ]; then
        local existing_link_target
        existing_link_target=$(readlink "$SCRIPT_PATH" 2>/dev/null)
        if [ "$existing_link_target" = "$SCRIPT_PATH" ] || [ ! -e "$SCRIPT_PATH" ]; then
            rm -f "$SCRIPT_PATH" 2>/dev/null
        fi
    fi

    target_real=$(readlink -f "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")

    if [ ! -s "$SCRIPT_PATH" ] || [ "$self_path" != "$target_real" ]; then
        [ ! -s "$SCRIPT_PATH" ] && was_first_install=true
        mkdir -p "$(dirname "$SCRIPT_PATH")" 2>/dev/null

        # $0 is NOT a normal, independently re-readable file when this
        # script is launched as `bash <(curl ...)` or `curl ... | bash` -
        # it's a process-substitution / pipe fd (e.g. /dev/fd/63). By the
        # time we get here, bash has already consumed that stream to parse
        # and start executing the script, so `cp` reading it again gets an
        # empty/truncated result. `cp` still exits 0 in that case, so the
        # old code reported success while /usr/local/bin/dexter-warp was
        # left missing or empty and its warp-dx symlink pointed at nothing
        # - exactly the "command not found" seen right after "[✓] Installed".
        # Detect that case and fetch a real copy from the canonical URL
        # instead of trying to copy an unreadable pipe.
        local self_is_pipe=false
        case "$self_path" in
            /dev/fd/*|/proc/self/fd/*|/proc/*/fd/*|pipe:*|"") self_is_pipe=true ;;
        esac
        [ "$self_is_pipe" = false ] && [ ! -f "$self_path" ] && self_is_pipe=true

        local install_ok=false
        if [ "$self_is_pipe" = true ]; then
            local tmp_self="/tmp/dexter-warp-self_$$.sh"
            if http_download "https://raw.githubusercontent.com/COD-DEXTER/WARP-DX/main/main.sh" -o "$tmp_self" \
               && [ -s "$tmp_self" ] && bash -n "$tmp_self" 2>/dev/null; then
                mv -f "$tmp_self" "$SCRIPT_PATH" 2>/dev/null && install_ok=true
            fi
            rm -f "$tmp_self" 2>/dev/null
        else
            cp -f "$self_path" "$SCRIPT_PATH" 2>/dev/null && [ -s "$SCRIPT_PATH" ] && install_ok=true
        fi

        if [ "$install_ok" = true ]; then
            chmod +x "$SCRIPT_PATH" 2>/dev/null
        else
            rm -f "$SCRIPT_PATH" 2>/dev/null
            log_msg "WARNING" "Could not install a real copy to $SCRIPT_PATH (pipe-mode=${self_is_pipe}; permission/network issue?)"
        fi
    fi

    local link_dir="/usr/local/bin"
    [ "$(id -u)" -ne 0 ] 2>/dev/null && link_dir="$(dirname "$SCRIPT_PATH")"

    # Remove a stale "warp" alias left behind by an older version of this
    # script (only "warp-dx" is meant to exist as a global command now).
    if [ -e "${link_dir}/warp" ] || [ -L "${link_dir}/warp" ]; then
        rm -f "${link_dir}/warp" 2>/dev/null
    fi

    # Only "warp-dx" is exposed as a global alias by design (the user
    # explicitly wants exactly one entry-point command, not "warp" too).
    # Never point it at a file that doesn't actually exist - that's what
    # produced the broken "command not found" symlink before.
    local links_ok=true
    local link_path="${link_dir}/warp-dx"
    if [ "$link_path" != "$SCRIPT_PATH" ]; then
        if [ -s "$SCRIPT_PATH" ] && [ -d "$link_dir" ] && [ -w "$link_dir" ] 2>/dev/null; then
            ln -sf "$SCRIPT_PATH" "$link_path" 2>/dev/null || links_ok=false
        else
            links_ok=false
        fi
    fi

    # A symlink existing on disk doesn't guarantee the shell can find it:
    # some minimal/Docker base images ship a $PATH that omits
    # /usr/local/bin entirely, which is exactly what produces "command not
    # found" right after a reported-successful install. Detect that case
    # and make the command reachable anyway instead of just claiming success.
    local path_has_dir=false
    case ":${PATH}:" in
        *":${link_dir}:"*) path_has_dir=true ;;
    esac

    if [ "$path_has_dir" = false ] && [ "$links_ok" = true ]; then
        local rc_file=""
        for rc_file in "$HOME/.bashrc" "$HOME/.profile" "/etc/profile.d/warp-dx.sh"; do
            local rc_dir
            rc_dir=$(dirname "$rc_file")
            [ -d "$rc_dir" ] && [ -w "$rc_dir" ] 2>/dev/null || continue
            if [ ! -f "$rc_file" ] || ! grep -qF "$link_dir" "$rc_file" 2>/dev/null; then
                printf '\nexport PATH="%s:$PATH"\n' "$link_dir" >> "$rc_file" 2>/dev/null
            fi
            break
        done
        export PATH="${link_dir}:${PATH}"
        # Note: this export only affects this script's own process, not
        # the interactive shell that launched it (a child process cannot
        # modify its parent's environment) - so the person still needs to
        # either open a new terminal or export PATH themselves right now.
        printf "%b\n" "${YELLOW}[!] '$link_dir' is not in this shell's \$PATH, so 'warp-dx' won't be found here yet.${NC}"
        printf "%b\n" "${YELLOW}    Run this once in your current terminal: ${CYAN}export PATH=\"${link_dir}:\$PATH\"${YELLOW}   (new terminals will have it automatically from now on)${NC}"
        log_msg "WARNING" "link_dir ($link_dir) missing from caller's PATH; appended to shell rc for future sessions"
    fi

    if [ "$was_first_install" = true ]; then
        if [ ! -s "$SCRIPT_PATH" ]; then
            printf "%b\n" "${RED}[ERROR] Could not install to $SCRIPT_PATH (no internet, or a permission issue). 'warp-dx' will not work yet - fix the underlying error above and re-run.${NC}"
            log_msg "ERROR" "Install failed: $SCRIPT_PATH was never created"
        elif [ "$links_ok" = true ] && [ "$path_has_dir" = true ]; then
            printf "%b\n" "${GREEN}[✓] Installed. From now on just run: ${CYAN}warp-dx${GREEN} from anywhere.${NC}"
            log_msg "INFO" "Global command installed at $SCRIPT_PATH, linked as ${link_dir}/warp-dx"
        elif [ "$links_ok" = false ]; then
            printf "%b\n" "${YELLOW}[!] Copied to $SCRIPT_PATH but could not create the warp-dx symlink (check permissions). Run with: $SCRIPT_PATH${NC}"
            log_msg "WARNING" "Symlink creation failed in $link_dir"
        fi
    fi
}

_print_cli_help() {
    printf "%b\n" "${CYAN}WARP DX v${VERSION} - usage:${NC}"
    printf "  %-22s %s\n" "warp" "Open the interactive menu"
    printf "  %-22s %s\n" "warp menu" "Same as above"
    printf "  %-22s %s\n" "warp up|connect|start" "Install (if needed) and connect"
    printf "  %-22s %s\n" "warp down|disconnect|stop" "Disconnect WARP"
    printf "  %-22s %s\n" "warp restart" "Restart the WARP service"
    printf "  %-22s %s\n" "warp status" "Show current connection status"
    printf "  %-22s %s\n" "warp install" "Run the full install flow"
    printf "  %-22s %s\n" "warp newip" "Rotate to a new WARP identity"
    printf "  %-22s %s\n" "warp optimize [--quiet]" "Test endpoints and switch to the best-scoring one (cron-friendly with --quiet)"
    printf "  %-22s %s\n" "warp logs" "View recent logs"
    printf "  %-22s %s\n" "warp version" "Print the script version"
}

# Dispatches CLI subcommands so "warp up", "warp down", "warp status", etc.
# all work consistently from any shell once installed, in addition to the
# plain interactive "warp" / "warp menu" entry point.
_dexter_warp_cli_dispatch() {
    case "${1:-menu}" in
        menu)
            dexter_warp_main_menu
            ;;
        up|connect|start)
            if dexter_warp_is_installed; then dexter_warp_connect; else dexter_warp_install; fi
            exit $?
            ;;
        down|disconnect|stop)
            dexter_warp_disconnect
            exit $?
            ;;
        restart)
            dexter_warp_restart
            exit $?
            ;;
        status)
            dexter_warp_status
            exit $?
            ;;
        install)
            dexter_warp_install
            exit $?
            ;;
        newip|new-identity)
            dexter_warp_new_identity
            exit $?
            ;;
        optimize)
            # Non-interactive, cron-friendly. This is the practical version
            # of "auto optimize every N hours": no built-in scheduler here
            # (that needs its own careful design around not disrupting an
            # active connection) - instead this subcommand does the actual
            # work and can be dropped straight into the user's own crontab,
            # e.g.: 0 */12 * * * /usr/local/bin/dexter-warp optimize --quiet
            if [ "${2:-}" = "--quiet" ] || [ "${2:-}" = "-q" ]; then
                dexter_warp_optimize_connection quiet >>"$(get_log_path)" 2>&1
            else
                dexter_warp_optimize_connection
            fi
            exit $?
            ;;
        logs)
            dexter_warp_view_logs
            exit $?
            ;;
        version|-v|--version)
            printf "%s\n" "$VERSION"
            exit 0
            ;;
        help|-h|--help)
            _print_cli_help
            exit 0
            ;;
        *)
            printf "%b\n" "${RED}Unknown command: ${1}${NC}"
            _print_cli_help
            exit 1
            ;;
    esac
}

# ========== Entry Point ==========
RUN_MODE="${RUN_MODE:-$(detect_environment)}"
CURRENT_MODE="$RUN_MODE"
detect_os
init_paths
load_config
CURRENT_MODE="$RUN_MODE"
_ensure_dirs
_reset_self_heal_state
_self_install_global_command

if ! acquire_lock; then
    _lock_holder_pid=""
    _lp="$(get_lock_path).pid"
    [ -f "$_lp" ] && read -r _lock_holder_pid < "$_lp" 2>/dev/null
    printf "%b\n" "${RED}[ERROR] Another instance is already running.${NC}"
    if [ -n "$_lock_holder_pid" ]; then
        printf "%b\n" "${YELLOW}    Held by PID ${_lock_holder_pid}. Check with: ps -p ${_lock_holder_pid}${NC}"
        printf "%b\n" "${YELLOW}    If that's a stuck/old session, you can force-clear it with: kill ${_lock_holder_pid} 2>/dev/null; rm -f $(get_lock_path) $(get_lock_path).pid${NC}"
    fi
    exit 1
fi

if ! dexter_warp_check_os; then
    printf "%b\n" "${RED}[ERROR] Operating system is not supported.${NC}"
    exit 1
fi

_dexter_warp_cli_dispatch "$@"
