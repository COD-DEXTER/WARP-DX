#!/bin/bash

# ========== Auto-install on first run ==========
SCRIPT_PATH="/usr/local/bin/dexter-warp"
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    echo -e "\033[0;33m[!] Installing dexter-warp to /usr/local/bin ...\033[0m"
    cp "$0" "$SCRIPT_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    echo -e "\033[0;32m[✓] Installed! Now run with: dexter-warp\033[0m"
fi

# ========== Colors & Version ==========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
VERSION="2"

[[ $EUID -ne 0 ]] && echo -e "${RED}Run this script as root.${NC}" && exit 1

# ========== Environment Detection ==========
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=true
else
    IS_ALPINE=false
fi

# ========== Core Checks ==========
dexter_warp_is_installed() {
    if [ "$IS_ALPINE" = true ]; then
        command -v wireproxy &>/dev/null
    else
        command -v warp-cli &>/dev/null
    fi
}

dexter_warp_is_connected() {
    if [ "$IS_ALPINE" = true ]; then
        pgrep wireproxy &>/dev/null && nc -z 127.0.0.1 10808 &>/dev/null
    else
        warp-cli status 2>/dev/null | grep -iq "Connected"
    fi
}

# ========== Helpers ==========
dexter_warp_get_out_ip() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip=""
    ip=$(curl -s --socks5 "${proxy_ip}:${proxy_port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --socks5 "${proxy_ip}:${proxy_port}" https://ifconfig.me 2>/dev/null)
    fi
    echo "$ip"
}

# ========== Core Functions ==========
dexter_warp_install() {
    if dexter_warp_is_installed && dexter_warp_is_connected; then
        echo -e "${GREEN}WARP is already installed and connected.${NC}"
        read -p "Do you want to reinstall it? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy] ]] && return
    fi

    if [ "$IS_ALPINE" = true ]; then
        echo -e "${CYAN}Alpine detected. Installing dependencies (curl, jq, wireguard-tools)...${NC}"
        apk update
        apk add curl jq wireguard-tools openssl || true

        echo -e "${CYAN}Downloading WireProxy binary...${NC}"
        local arch
        arch=$(uname -m)
        local download_url="https://github.com/octeep/wireproxy/releases/latest/download/wireproxy_linux_amd64.tar.gz"
        if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
            download_url="https://github.com/octeep/wireproxy/releases/latest/download/wireproxy_linux_arm64.tar.gz"
        fi

        curl -L -o /tmp/wireproxy.tar.gz "$download_url"
        tar -xzf /tmp/wireproxy.tar.gz -C /usr/local/bin/ wireproxy
        chmod +x /usr/local/bin/wireproxy
        rm -f /tmp/wireproxy.tar.gz

        dexter_warp_connect
    else
        echo -e "${CYAN}Debian/Ubuntu detected. Installing WARP-CLI...${NC}"
        local codename=$(lsb_release -cs 2>/dev/null || echo "")
        [[ "$codename" == "oracular" ]] && codename="jammy"

        apt update
        apt install -y curl gpg lsb-release apt-transport-https ca-certificates sudo jq
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" > /etc/apt/sources.list.d/cloudflare-client.list
        apt update
        apt install -y cloudflare-warp
        dexter_warp_connect
    fi
}

dexter_warp_connect() {
    if [ "$IS_ALPINE" = true ]; then
        echo -e "${BLUE}Starting WireProxy Configuration & Connection...${NC}"
        
        if [ ! -f /etc/wireproxy.conf ]; then
            echo -e "${CYAN}Generating new WARP registration...${NC}"
            local private_key=$(wg genkey)
            local public_key=$(echo "$private_key" | wg pubkey)
            
            local response=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
              -H "Content-Type: application/json" \
              -H "User-Agent: okhttp/3.12.1" \
              -d "{\"key\":\"$public_key\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"type\":\"ios\",\"locale\":\"en_US\"}")

            local id=$(echo "$response" | jq -r '.result.id')
            local token=$(echo "$response" | jq -r '.result.token')
            local ipv4=$(echo "$response" | jq -r '.result.config.interface.addresses.v4')
            local peer_pubkey=$(echo "$response" | jq -r '.result.config.peers[0].public_key')
            local peer_endpoint=$(echo "$response" | jq -r '.result.config.peers[0].endpoint.v4')

            if [[ -z "$id" || "$id" == "null" ]]; then
                echo -e "${RED}[ERROR] Failed to register WARP with Cloudflare API.${NC}"
                return 1
            fi

            curl -s -X PATCH "https://api.cloudflareclient.com/v0a2158/reg/$id" \
              -H "Content-Type: application/json" \
              -H "Authorization: Bearer $token" \
              -H "User-Agent: okhttp/3.12.1" \
              -d '{"warp_enabled":true}' >/dev/null

            mkdir -p /etc
            cat <<EOF > /etc/wireproxy.conf
[WG]
SelfInterface = $ipv4
PrivateKey = $private_key
DNS = 1.1.1.1

[Peer]
PublicKey = $peer_pubkey
Endpoint = $peer_endpoint
KeepAlive = 25

[Socks5]
BindAddress = 127.0.0.1:10808
EOF
        fi

        echo -e "${BLUE}Running WireProxy in background...${NC}"
        pkill -f wireproxy 2>/dev/null || kill $(pgrep wireproxy) 2>/dev/null || true
        nohup /usr/local/bin/wireproxy -c /etc/wireproxy.conf >/dev/null 2>&1 &
        sleep 3
    else
        echo -e "${BLUE}Connecting to WARP Proxy...${NC}"
        yes | warp-cli registration new
        warp-cli mode proxy
        warp-cli proxy port 10808
        warp-cli connect
        sleep 2
    fi
}

dexter_warp_disconnect() {
    echo -e "${YELLOW}Disconnecting WARP...${NC}"
    if [ "$IS_ALPINE" = true ]; then
        pkill -f wireproxy 2>/dev/null || kill $(pgrep wireproxy) 2>/dev/null || true
    else
        warp-cli disconnect 2>/dev/null
    fi
    sleep 1
}

dexter_warp_status() {
    if [ "$IS_ALPINE" = true ]; then
        if dexter_warp_is_connected; then
            echo -e "WARP Status: ${GREEN}CONNECTED${NC} (via WireProxy SOCKS5: 127.0.0.1:10808)"
        else
            echo -e "WARP Status: ${RED}NOT CONNECTED${NC}"
        fi
    else
        warp-cli status
    fi
}

dexter_warp_test_proxy() {
    echo -e "${CYAN}Testing SOCKS5 proxy (127.0.0.1:10808)...${NC}"
    local ip=$(dexter_warp_get_out_ip)
    if [[ -n "$ip" ]]; then
        echo -e "[OK] Outgoing IP via WARP: ${GREEN}$ip${NC}"
    else
        echo -e "[FAIL] ${RED}Could not get IP via proxy. Is WARP connected?${NC}"
    fi
}

dexter_warp_remove() {
    echo -e "${RED}Removing WARP...${NC}"
    if [ "$IS_ALPINE" = true ]; then
        pkill -f wireproxy 2>/dev/null || kill $(pgrep wireproxy) 2>/dev/null || true
        rm -f /usr/local/bin/wireproxy
        rm -f /etc/wireproxy.conf
        echo -e "${GREEN}WireProxy removed.${NC}"
    else
        apt remove --purge -y cloudflare-warp
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        apt autoremove -y
        echo -e "${GREEN}WARP removed.${NC}"
    fi
}

dexter_warp_quick_change_ip() {
    if ! dexter_warp_is_installed; then
        echo -e "${RED}WARP is not installed.${NC}"
        return 1
    fi
    echo -e "${CYAN}Trying quick IP change (disconnect/connect)...${NC}"
    local old_ip new_ip
    old_ip=$(dexter_warp_get_out_ip)
    echo -e "Current IP: ${YELLOW}${old_ip:-N/A}${NC}"

    for attempt in {1..5}; do
        echo -e "Attempt ${attempt}/5: reconnecting..."
        dexter_warp_disconnect
        
        if [ "$IS_ALPINE" = true ]; then
            nohup /usr/local/bin/wireproxy -c /etc/wireproxy.conf >/dev/null 2>&1 &
            sleep 3
        else
            warp-cli connect
            sleep 2
        fi
        
        new_ip=$(dexter_warp_get_out_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "[✓] New IP: ${GREEN}$new_ip${NC}"
            return 0
        fi
    done

    echo -e "${YELLOW}IP did not change with quick method. Try 'New Identity' option.${NC}"
    return 2
}

dexter_warp_new_identity() {
    if ! dexter_warp_is_installed; then
        echo -e "${RED}WARP is not installed.${NC}"
        return 1
    fi
    echo -e "${CYAN}Issuing a fresh registration (this almost always changes the IP)...${NC}"
    local old_ip new_ip
    old_ip=$(dexter_warp_get_out_ip)
    echo -e "Old IP: ${YELLOW}${old_ip:-N/A}${NC}"

    dexter_warp_disconnect

    if [ "$IS_ALPINE" = true ]; then
        rm -f /etc/wireproxy.conf
        dexter_warp_connect
    else
        warp-cli registration delete 2>/dev/null || \
        warp-cli deregister 2>/dev/null || \
        warp-cli registration revoke 2>/dev/null

        sleep 1
        yes | warp-cli registration new
        warp-cli mode proxy
        warp-cli proxy port 10808
        warp-cli connect
        sleep 2
    fi

    new_ip=$(dexter_warp_get_out_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "[✓] New IP: ${GREEN}$new_ip${NC}"
        else
            echo -e "${YELLOW}Identity refreshed but IP looks the same. Try again later or from another network.${NC}"
        fi
    else
        echo -e "${RED}Could not obtain new IP after re-registration.${NC}"
        return 2
    fi
}

# ========== Menu ==========
dexter_warp_draw_menu() {
    clear
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local is_connected="no"
    dexter_warp_is_connected && is_connected="yes"
    local socks5_ip="N/A"
    [[ "$is_connected" == "yes" ]] && socks5_ip=$(dexter_warp_get_out_ip || echo "N/A")

    cat << "EOF"
 ██╗    ██╗  █████╗  ██████╗  ██████╗      ██████╗  ██╗  ██╗
 ██║    ██║ ██╔══██╗ ██╔══██╗ ██╔══██╗     ██╔══██╗ ╚██╗██╔╝
 ██║ █╗ ██║ ███████║ ██████╔╝ ██████╔╝     ██║  ██║  ╚███╔╝ 
 ██║███╗██║ ██╔══██║ ██╔══██╗ ██╔═══╝      ██║  ██║  ██╔██╗ 
 ╚███╔███╔╝ ██║  ██║ ██║  ██║ ██║          ██████╔╝ ██╔╝ ██╗
  ╚══╝╚══╝  ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝          ╚═════╝  ╚═╝  ╚═╝
+-------------------------------------------------------------------+
EOF
    echo -e "| Creator/Telegram: ${YELLOW}@COD_DEXTER${NC}                      | Version: ${GREEN}${VERSION}${NC}   |"
    echo "+-------------------------------------------------------------------+"
    if [[ "$is_connected" == "yes" ]]; then
        echo -e "| WARP Status: ${GREEN}CONNECTED${NC}"
        echo -e "| Proxy SOCKS5: ${CYAN}${proxy_ip}:${proxy_port}${NC}"
        echo -e "| Outgoing IP: ${YELLOW}${socks5_ip}${NC}"
    else
        echo -e "| WARP Status: ${RED}NOT CONNECTED${NC}"
    fi
    echo "+-------------------------------------------------------------------+"
    echo -e "| ${YELLOW}Choose an option:${NC}"
    echo "+-------------------------------------------------------------------+"
    echo -e "| 1 - Install WARP"
    echo -e "| 2 - Show Status"
    echo -e "| 3 - Test Proxy"
    echo -e "| 4 - Remove WARP"
    echo -e "| 5 - Change IP (Quick reconnect)"
    echo -e "| 6 - Change IP (New Identity - stronger)"
    echo -e "| 0 - Exit"
    echo "+-------------------------------------------------------------------+"
    echo -ne "${YELLOW}Select option: ${NC}"
}

dexter_warp_main_menu() {
    while true; do
        dexter_warp_draw_menu
        read -r choice
        case $choice in
            1) dexter_warp_install ;;
            2) dexter_warp_status ;;
            3) dexter_warp_test_proxy ;;
            4) dexter_warp_remove ;;
            5) dexter_warp_quick_change_ip ;;
            6) dexter_warp_new_identity ;;
            0) echo -e "${GREEN}Exiting...${NC}"; exit ;;
            *) echo -e "${RED}Invalid choice. Try again.${NC}" ;;
        esac
        echo -e "\nPress Enter to return to menu..."
        read -r
    done
}

# ========== Run Menu ==========
dexter_warp_main_menu
