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
    if [[ "$host" =~ ^[0-9a-fA-F.:]+$ ]] && [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
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
    if [ "$PATHS_INITIALIZED" = false ]; then
        init_paths
        _ensure_dirs
    fi
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
    pkill -P "$$" 2>/dev/null || true
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
trap safe_cleanup EXIT INT TERM HUP

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
    curl -s --connect-timeout 5 --max-time 10 https://1.1.1.1 >/dev/null 2>&1
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
    if [ -f /proc/net/if_inet6 ] 2>/dev/null; then
        local iface
        while IFS= read -r iface; do
            local iface_name="${iface%% *}"
            [ "$iface_name" = "lo" ] && continue
            local path="/proc/sys/net/ipv6/conf/${iface_name}/disable_ipv6"
            if [ -f "$path" ] 2>/dev/null; then
                local disabled
                read -r disabled < "$path" 2>/dev/null || disabled="1"
                [ "$disabled" = "0" ] && return 0
            fi
        done < /proc/net/if_inet6
    fi
    ip -6 route show default >/dev/null 2>&1 && return 0
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
    curl -s --fail --retry 2 --connect-timeout 3 --max-time 5 "$@" "$url" 2>/dev/null
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
    if command -v ss &>/dev/null; then
        ss -H -tln "sport = :$port" 2>/dev/null | grep -q . && return 0
    fi
    
    # Active SOCKS5 State verification (TCP_LISTEN is represented by hex code "0A")
    local files="/proc/net/tcp"
    [ -f /proc/net/tcp6 ] && files="$files /proc/net/tcp6"
    
    local hex_port
    hex_port=$(printf '%04X' "$port")
    local line
    for f in $files; do
        if [ -f "$f" ]; then
            while IFS= read -r line; do
                case "$line" in
                    *":${hex_port}"*"0A"*) return 0 ;;
                esac
            done < "$f"
        fi
    done

    if command -v lsof &>/dev/null; then
        lsof -i :"$port" -sTCP:LISTEN &>/dev/null && return 0
    fi
    if command -v netstat &>/dev/null; then
        netstat -an 2>/dev/null | grep -q -E "LISTEN.*:$port" && return 0
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
    [ -z "$ip" ] && return
    mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
    printf '%s\n%s\n' "$ip" "$(date +%s)" > "$CACHE_FILE" 2>/dev/null
    CACHED_IP="$ip"
    LAST_IP_CHECK=$(date +%s)
}

read_cache() {
    if [ -f "$CACHE_FILE" ]; then
        local cached_ip="" cached_time=""
        read -r cached_ip cached_time < "$CACHE_FILE" 2>/dev/null || { cached_ip=""; cached_time=""; }
        if [ -n "$cached_ip" ] && [[ "$cached_time" =~ ^[0-9]+$ ]]; then
            local now
            now=$(date +%s)
            local age=$((now - cached_time))
            if [ "$age" -lt "$IP_CACHE_TTL" ] 2>/dev/null; then
                CACHED_IP="$cached_ip"
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
    if [ -z "$ip" ]; then
        ip=$(http_get "https://api.ipify.org" 2>/dev/null)
    fi
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
    # Force IPv4 explicit selection (-4) to bypass Railway/Docker broken IPv6 routing deadlocks
    http_get "${CF_API}/reg" -4 -X POST \
      -H "Content-Type: application/json" \
      -H "User-Agent: okhttp/3.12.1" \
      -d "$payload"
}

cf_update() {
    local id="$1"
    local token="$2"
    # Force IPv4 explicitly
    http_get "${CF_API}/reg/${id}" -4 -X PATCH \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${token}" \
      -H "User-Agent: okhttp/3.12.1" \
      -d '{"warp_enabled":true}'
}

cf_delete() {
    local id="$1"
    local token="$2"
    # Force IPv4 explicitly
    http_get "${CF_API}/reg/${id}" -4 -X DELETE \
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

    local direct_url="https://github.com/octeep/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
    local mirror_url="https://mirror.ghproxy.com/${direct_url}"
    local fallback_url="https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_linux_${arch}.tar.gz"
    local temp_archive="/tmp/wireproxy_$$.tar.gz"
    local extract_dir="/tmp/wp_extract_$$"
    TEMP_DIRS+=("$extract_dir")
    local bin_path
    bin_path=$(get_wireproxy_bin_path)
    local install_dir
    install_dir=$(dirname "$bin_path")

    http_download "$direct_url" -o "$temp_archive" 2>/dev/null || \
    http_download "$mirror_url" -o "$temp_archive" 2>/dev/null || \
    http_download "$fallback_url" -o "$temp_archive" 2>/dev/null || {
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
    nohup "$WIREPROXY_BIN" -c "$WIREPROXY_CONF" >/dev/null 2>&1 &
    local new_pid=$!
    printf '%s\n' "$new_pid" > "$pid_file" 2>/dev/null
    sleep 1
    if ! kill -0 "$new_pid" 2>/dev/null; then
        log_msg "ERROR" "WireProxy process died immediately after launch"
        return 1
    fi
    return 0
}

_service_stop() {
    if [ "$CURRENT_MODE" = "VPS" ]; then
        if [ "$IS_ALPINE" = true ] && [ -f /etc/init.d/wireproxy ] && command -v rc-service &>/dev/null; then
            rc-service wireproxy stop &>/dev/null || true
            wait_for_port "$SOCKS5_PORT" 10 0.5
            return
        fi
        if [ -f /etc/systemd/system/wireproxy.service ] && command -v systemctl &>/dev/null; then
            systemctl stop wireproxy &>/dev/null || true
            wait_for_port "$SOCKS5_PORT" 10 0.5
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
    wait_for_port "$SOCKS5_PORT" 10 0.5
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
    private_key=$(wg genkey 2>/dev/null || openssl rand -base64 32 2>/dev/null || dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 2>/dev/null | tr -d '\r\n')

    if [ -z "$private_key" ]; then
        printf "%b\n" "${RED}[ERROR] WireGuard key generation failed.${NC}"
        return 1
    fi

    local public_key=""
    public_key=$(printf '%s' "$private_key" | wg pubkey 2>/dev/null)

    if [ -z "$public_key" ]; then
        printf "%b\n" "${RED}[ERROR] WireGuard public key derivation failed.${NC}"
        return 1
    fi

    local response=""
    local success=false
    local attempt

    for attempt in 1 2 3; do
        if ! check_internet; then
            log_msg "WARNING" "No internet during registration attempt $attempt"
            local backoff=$((attempt * 3))
            sleep "$backoff"
            continue
        fi
        response=$(cf_register "$public_key")

        if [ -n "$response" ] && [ "$response" != "null" ]; then
            local check_id
            if command -v jq &>/dev/null; then
                check_id=$(echo "$response" | jq -r '.result.id' 2>/dev/null)
            else
                check_id=$(echo "$response" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' 2>/dev/null | head -n1)
            fi
            if [[ -n "$check_id" ]] && [ "$check_id" != "null" ]; then
                success=true
                break
            fi
        fi
        sleep "$((attempt * 2))"
    done

    if [ "$success" = false ]; then
        log_msg "ERROR" "Cloudflare registration failed after 3 attempts"
        return 1
    fi

    WG_PRIV_KEY="$private_key"

    if command -v jq &>/dev/null; then
        WG_PEER_PUB_KEY=$(echo "$response" | jq -r '.result.config.peers[0].public_key // empty' 2>/dev/null)
        WG_PEER_ENDPOINT=$(echo "$response" | jq -r '.result.config.peers[0].endpoint.v4 // empty' 2>/dev/null)
        WG_IPV4=$(echo "$response" | jq -r '.result.config.interface.addresses.v4 // empty' 2>/dev/null)
        WG_IPV6=$(echo "$response" | jq -r '.result.config.interface.addresses.v6 // empty' 2>/dev/null)
        WG_REG_ID=$(echo "$response" | jq -r '.result.id // empty' 2>/dev/null)
        WG_REG_TOKEN=$(echo "$response" | jq -r '.result.token // empty' 2>/dev/null)
    else
        log_msg "WARNING" "jq not available, using sed fallback for JSON parsing"
        WG_PEER_PUB_KEY=$(echo "$response" | sed -n 's/.*"public_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n1)
        WG_PEER_ENDPOINT=$(echo "$response" | sed -n 's/.*"v4"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n1)
        WG_IPV4=$(echo "$response" | grep -o '"v4"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
        WG_IPV6=$(echo "$response" | grep -o '"v6"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
        WG_REG_ID=$(echo "$response" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([a-f0-9-]*\)".*/\1/p' 2>/dev/null | head -n1)
        WG_REG_TOKEN=$(echo "$response" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n1)
    fi

    [ -z "$WG_PEER_PUB_KEY" ] || [ "$WG_PEER_PUB_KEY" = "null" ] && { log_msg "ERROR" "Invalid peer public key from API"; return 1; }
    [ -z "$WG_PEER_ENDPOINT" ] || [ "$WG_PEER_ENDPOINT" = "null" ] && { log_msg "ERROR" "Invalid endpoint from API"; return 1; }
    [ -z "$WG_IPV4" ] || [ "$WG_IPV4" = "null" ] && { log_msg "ERROR" "Invalid IPv4 from API"; return 1; }

    save_config
    dexter_warp_generate_wireproxy_conf "$WG_IPV4" "$WG_PRIV_KEY" "$WG_PEER_PUB_KEY" "$WG_PEER_ENDPOINT" "$WG_IPV6"
}

dexter_warp_generate_wireproxy_conf() {
    local ipv4="$1"
    local private_key="$2"
    local peer_pubkey="$3"
    local peer_endpoint="$4"
    local ipv6="$5"

    local self_interface=""
    local dns_servers=""

    case "$IP_VERSION" in
        4)
            self_interface="$ipv4"
            dns_servers="1.1.1.1"
            ;;
        6)
            if ! check_ipv6_available; then
                printf "%b\n" "${YELLOW}[WARNING] IPv6 not available on this system. Falling back to IPv4.${NC}"
                IP_VERSION="4"
                self_interface="$ipv4"
                dns_servers="1.1.1.1"
            else
                self_interface="$ipv6"
                dns_servers="2606:4700:4700::1111"
            fi
            ;;
        dual)
            if check_ipv6_available; then
                self_interface="${ipv4}, ${ipv6}"
                dns_servers="1.1.1.1, 2606:4700:4700::1111"
            else
                self_interface="$ipv4"
                dns_servers="1.1.1.1"
            fi
            ;;
    esac

    mkdir -p "$(dirname "$WIREPROXY_CONF")" 2>/dev/null || true
    local tmp_conf="${WIREPROXY_CONF}.tmp.$$"
    cat <<EOF > "$tmp_conf"
[WG]
SelfInterface = $self_interface
PrivateKey = $private_key
DNS = $dns_servers

[Peer]
PublicKey = $peer_pubkey
Endpoint = $peer_endpoint
KeepAlive = 25

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
        result=$(http_get "$ep" $proxy_args 2>/dev/null)
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
            return 1
        fi
        if ! dexter_warp_register_api; then
            end_spin "FAILED" "${T[reg_fail]}"
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
        return 1
    fi
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
# Section 22: Port & Config Management
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
    dexter_warp_connect

    local success=false
    local i
    for ((i = 1; i <= 15; i++)); do
        if port_in_use "$SOCKS5_PORT"; then
            local test_bypass
            test_bypass=$(cf_trace "--socks5 ${PROXY_IP}:${SOCKS5_PORT}")
            if [ -n "$test_bypass" ]; then
                success=true
                break
            fi
        fi
        sleep 0.5
    done

    if [ "$success" = true ]; then
        printf "%b\n" "${GREEN}[✓] SOCKS5 port changed to $PROXY_IP:$SOCKS5_PORT.${NC}"
        log_msg "INFO" "SOCKS5 port changed to $PROXY_IP:$SOCKS5_PORT"
    else
        printf "%b\n" "${RED}[WARNING] Port changed but verification timed out.${NC}"
        log_msg "WARNING" "SOCKS5 port changed but verify timed out"
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
        2) IP_VERSION="dual" ;;
        3)
            if ! check_ipv6_available; then
                printf "%b\n" "${RED}[ERROR] IPv6 is not available on this system. Cannot switch to IPv6-only mode.${NC}"
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
    printf "%b\n" "${CYAN}+-------------------------------------------------------------+${NC}"
    printf "%b\n" "|                       WARP DX v${VERSION}                            |"
    printf "%b\n" "|  A professional hybrid WARP client installer and SOCKS5 proxy  |"
    printf "%b\n" "|  manager supporting Ubuntu, Debian, Alpine Linux, and Docker.|"
    printf "%b\n" "|                                                             |"
    printf "%b\n" "|  Created by: ${YELLOW}@COD-DEXTER${NC}                                    |"
    printf "%b\n" "+-------------------------------------------------------------+${NC}"
}

# ==========================================
# Section 24: Menu System
# ==========================================
dexter_warp_draw_menu() {
    if is_minimal; then
        printf "\n${CYAN}=== WARP DX v${VERSION} ===${NC}\n"
        dexter_warp_is_connected && printf "${GREEN}Status: CONNECTED${NC}\n" || printf "${RED}Status: DISCONNECTED${NC}\n"
        printf "%b\n" "  1-Install  2-Status  3-Test  4-Remove  5-QuickIP"
        printf "%b\n" "  6-NewID  7-Port  8-Restart  9-Logs  10-Bkp/Rst"
        printf "%b\n" "  11-Reset  12-RunMode  13-IPMode  14-Update  15-About  0-Exit"
        echo -ne "${YELLOW}Select: ${NC}"
        return
    fi

    clear
    local is_connected="no"
    dexter_warp_is_connected && is_connected="yes"
    local socks5_ip="N/A"

    if [ "$is_connected" = "yes" ]; then
        socks5_ip=$(dexter_warp_get_out_ip_cached 2>/dev/null || echo "N/A")
    fi

    print_line() {
        is_minimal && return 0
        local left_content="$1"
        local clean_content
        if [ -n "$BASH_VERSION" ]; then
            local esc
            esc=$(printf '\033')
            clean_content="$left_content"
            # Cyberpunk strip ANSI patterns
            while [[ "$clean_content" =~ ${esc}\[[^a-zA-Z]*[a-zA-Z] ]]; do
                clean_content="${clean_content//"${BASH_REMATCH[0]}"/}"
            done
        else
            clean_content=$(printf '%s' "$left_content" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null)
        fi
        local len=${#clean_content}
        local pad=$((67 - len))
        if [ "$pad" -lt 0 ]; then
            left_content="${left_content:0:62}..."
            pad=0
        fi
        local spaces=""
        if [ "$pad" -gt 0 ]; then
            spaces=$(printf '%*s' "$pad" "")
        fi
        printf "%b\n" "${CYAN}|${NC}${left_content}${spaces}${CYAN}|${NC}"
    }

    # Banners and Title Block (60 chars wide to fit easily without breaking boundaries)
    printf "%b\n" " ${MAGENTA}██╗    ██╗  █████╗  ██████╗  ██████╗      ██████╗  ██╗  ██╗${NC}"
    printf "%b\n" " ${YELLOW}██║    ██║ ██╔══██╗ ██╔══██╗ ██╔══██╗     ██╔══██╗ ╚██╗██╔╝${NC}"
    printf "%b\n" " ${YELLOW}██║ █╗ ██║ ███████║ ██████╔╝ ██████╔╝     ██║  ██║  ╚███╔╝  ${GREEN}WARP${NC}"
    printf "%b\n" " ${YELLOW}██║███╗██║ ██╔══██║ ██╔══██╗ ██╔═══╝      ██║  ██║  ██╔██╗  ${GREEN} DX${NC}"
    printf "%b\n" " ${YELLOW}╚███╔███╔╝ ██║  ██║ ██║  ██║ ██║          ██████╔╝ ██╔╝ ██╗${NC}"
    printf "%b\n" "  ${YELLOW}╚══╝╚══╝  ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝          ╚═════╝  ╚═╝  ╚═╝${NC}"
    
    printf "%b\n" "${CYAN}+-------------------------------------------------------------------+${NC}"
    print_line " Telegram Channel: ${MAGENTA}@COD-DEXTER${NC}                      | Version: ${GREEN}${VERSION}${NC}"
    printf "%b\n" "${CYAN}+-------------------------------------------------------------------+${NC}"

    if [ "$is_connected" = "yes" ]; then
        print_line " WARP Status: ${GREEN}CONNECTED${NC}"
        print_line " Proxy: ${CYAN}${PROXY_IP}:${SOCKS5_PORT}${NC}"
        print_line " Out IP: ${YELLOW}${socks5_ip}${NC}"
    else
        print_line " WARP Status: ${RED}NOT CONNECTED${NC}"
    fi
    printf "%b\n" "${CYAN}+-------------------------------------------------------------------+${NC}"

    print_line " ${YELLOW}Choose an option:${NC}"
    printf "%b\n" "${CYAN}+-------------------------------------------------------------------+${NC}"
    print_line "  ${BLUE}1${NC} - Install WARP"
    print_line "  ${BLUE}2${NC} - Show Status"
    print_line "  ${BLUE}3${NC} - Test Proxy"
    print_line "  ${BLUE}4${NC} - Remove WARP"
    print_line "  ${BLUE}5${NC} - Change IP (Quick reconnect)"
    print_line "  ${BLUE}6${NC} - Change IP (New Identity - stronger)"
    print_line "  ${BLUE}7${NC} - Change SOCKS5 Port & Bind IP"
    print_line "  ${BLUE}8${NC} - Restart WARP"
    print_line "  ${BLUE}9${NC} - View Logs"
    print_line "  ${BLUE}10${NC} - Backup/Restore Configurations"
    print_line "  ${BLUE}11${NC} - Reset Configurations"
    print_line "  ${BLUE}12${NC} - Switch Script Run Mode (Current: $(dexter_warp_get_run_mode_label))"
    print_line "  ${BLUE}13${NC} - Switch IP Version Mode (Current: $(dexter_warp_get_mode_label))"
    print_line "  ${BLUE}14${NC} - Check For Update"
    print_line "  ${BLUE}15${NC} - About"
    print_line "  ${BLUE}0${NC} - Exit"
    printf "%b\n" "${CYAN}+-------------------------------------------------------------------+${NC}"
    printf "%b" "${YELLOW}Select option: ${NC}"
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
            6)  dexter_warp_new_identity ;;
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

# ========== Entry Point ==========
RUN_MODE="${RUN_MODE:-$(detect_environment)}"
CURRENT_MODE="$RUN_MODE"
detect_os
init_paths
load_config
CURRENT_MODE="$RUN_MODE"
_ensure_dirs
_reset_self_heal_state

if ! acquire_lock; then
    printf "%b\n" "${RED}[ERROR] Another instance is already running.${NC}"
    exit 1
fi

dexter_warp_main_menu
