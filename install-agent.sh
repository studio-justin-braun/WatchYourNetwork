#!/usr/bin/env bash
# WatchYourNetwork — Agent Installer
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/wyn-agent"
CONFIG_DIR="/etc/wyn"
SERVICE="wyn-agent"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/wyn-agent"

# ── Helpers ────────────────────────────────────────────────────────────────────

ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${CYAN}  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}"; exit 1; }
ask()  { local prompt="$1" default="$2" var="$3"; read -rp "  $prompt [$default]: " "$var"; eval "$var=\"\${$var:-$default}\""; }

banner() {
echo -e "${BLUE}"
cat <<'EOF'
  ██╗    ██╗██╗   ██╗███╗   ██╗     █████╗  ██████╗ ███████╗███╗   ██╗████████╗
  ██║    ██║╚██╗ ██╔╝████╗  ██║    ██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝
  ██║ █╗ ██║ ╚████╔╝ ██╔██╗ ██║    ███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║
  ██║███╗██║  ╚██╔╝  ██║╚██╗██║    ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║
  ╚███╔███╔╝   ██║   ██║ ╚████║    ██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║
   ╚══╝╚══╝    ╚═╝   ╚═╝  ╚═══╝    ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝
EOF
echo -e "${NC}${CYAN}  WatchYourNetwork — Agent Installer${NC}"
echo ""
}

# ── OS detection ───────────────────────────────────────────────────────────────

detect_os() {
    PKG_MANAGER="unknown"
    [[ -f /etc/os-release ]] && source /etc/os-release || true
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    PRETTY="${PRETTY_NAME:-$OS_ID}"

    if echo "$OS_ID $OS_LIKE" | grep -qiE "ubuntu|debian|mint|pop"; then
        PKG_MANAGER="apt"
    elif echo "$OS_ID $OS_LIKE" | grep -qiE "rhel|centos|rocky|alma|fedora"; then
        command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
    elif echo "$OS_ID" | grep -qiE "arch|manjaro"; then
        PKG_MANAGER="pacman"
    elif echo "$OS_ID" | grep -qi "alpine"; then
        PKG_MANAGER="apk"
    elif echo "$OS_ID $OS_LIKE" | grep -qi "suse"; then
        PKG_MANAGER="zypper"
    fi

    info "System: $PRETTY"
    info "Package manager: $PKG_MANAGER"
}

# ── Python ─────────────────────────────────────────────────────────────────────

ensure_python() {
    if command -v python3 &>/dev/null; then
        local ver
        ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        local major="${ver%%.*}" minor="${ver##*.}"
        if [[ $major -ge 3 && $minor -ge 10 ]]; then
            ok "Python $ver found"; return
        fi
        warn "Python $ver found but 3.10+ required"
    fi

    echo -e "${YELLOW}Installing Python 3.10+…${NC}"
    case "$PKG_MANAGER" in
        apt)     apt-get install -y python3 python3-pip python3-dev ;;
        dnf)     dnf install -y python3 python3-pip ;;
        yum)     yum install -y python3 python3-pip ;;
        pacman)  pacman -Sy --noconfirm python python-pip ;;
        apk)     apk add --no-cache python3 py3-pip ;;
        zypper)  zypper install -y python3 python3-pip ;;
        *)       die "Install Python 3.10+ manually, then re-run this script." ;;
    esac
    ok "Python installed"
}

# ── pip install (no venv) ──────────────────────────────────────────────────────

pip_install() {
    local req="$1"
    local flags=""
    if pip3 install --help 2>/dev/null | grep -q "break-system-packages"; then
        flags="--break-system-packages --ignore-installed"
    fi
    echo -e "${YELLOW}Installing Python packages…${NC}"
    pip3 install $flags -r "$req"
    ok "Python packages installed"
}

# ── Detect network interfaces ──────────────────────────────────────────────────

list_interfaces() {
    echo ""
    echo -e "${BOLD}Available network interfaces:${NC}"
    local idx=1
    declare -g -A IF_MAP=()
    while IFS= read -r iface; do
        local ip
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\S+' | head -1 || echo "no IP")
        echo "  $idx) $iface  ($ip)"
        IF_MAP[$idx]="$iface"
        ((idx++))
    done < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^lo$')
    echo ""
}

choose_interface() {
    list_interfaces
    local choice
    ask "Enter interface name or number" "eth0" choice

    # If numeric, resolve from map
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ -n "${IF_MAP[$choice]+x}" ]]; then
        IFACE="${IF_MAP[$choice]}"
    else
        IFACE="$choice"
    fi
    ok "Interface: $IFACE"
}

# ── Agent configuration ────────────────────────────────────────────────────────

configure_agent() {
    local default_hostname
    default_hostname=$(hostname -s)

    echo ""
    echo -e "${BOLD}WYN Server Connection${NC}"
    echo ""

    local server_input
    ask "WYN Server IP or hostname" "" server_input
    [[ -z "$server_input" ]] && die "Server IP/hostname is required."
    SERVER_HOST="$server_input"

    ask "WYN Server agent port" "8765" AGENT_PORT

    echo ""
    echo -e "${BOLD}Node Identity${NC}"
    echo ""
    ask "Node ID  (unique, no spaces)" "$default_hostname" NODE_ID
    ask "Node display name" "$default_hostname" NODE_NAME

    choose_interface

    echo ""
    info "Server  → ${SERVER_HOST}:${AGENT_PORT}"
    info "Node ID → $NODE_ID  ($NODE_NAME)"
    info "Iface   → $IFACE"
    echo ""
}

# ── Write config ───────────────────────────────────────────────────────────────

write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/agent.conf" <<EOF
server:
  host: "${SERVER_HOST}"
  port: ${AGENT_PORT}
  reconnect_interval_s: 10

node:
  id: "${NODE_ID}"
  name: "${NODE_NAME}"
  color: null

capture:
  interfaces:
    - ${IFACE}
  bpf_filter: ""
  ignore_loopback: true
  ignore_multicast: true
  ignore_arp: true
  track_processes: false
  snap_length: 96

report:
  batch_interval_ms: 50
  heartbeat_interval_s: 5
  max_batch_size: 500
EOF
    ok "Config written to $CONFIG_DIR/agent.conf"
}

# ── Install files ──────────────────────────────────────────────────────────────

install_files() {
    mkdir -p "$INSTALL_DIR"
    cp "$AGENT_DIR/agent.py"         "$INSTALL_DIR/"
    cp "$AGENT_DIR/requirements.txt" "$INSTALL_DIR/"
    ok "Agent files installed to $INSTALL_DIR"
}

# ── systemd service ────────────────────────────────────────────────────────────

install_service() {
    cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=WatchYourNetwork Agent (${NODE_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v python3) $INSTALL_DIR/agent.py --config $CONFIG_DIR/agent.conf
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE"
    ok "systemd service installed and enabled"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    banner

    if [[ $EUID -ne 0 ]]; then
        die "Run with sudo: sudo bash $0"
    fi

    detect_os
    echo ""
    ensure_python
    configure_agent
    write_config
    pip_install "$AGENT_DIR/requirements.txt"
    install_files

    echo ""
    local install_svc
    ask "Install as systemd service?" "y" install_svc
    if [[ "${install_svc,,}" == "y" ]]; then
        install_service

        local start_now
        ask "Start agent now?" "y" start_now
        if [[ "${start_now,,}" == "y" ]]; then
            systemctl start "$SERVICE"
            sleep 1
            if systemctl is-active --quiet "$SERVICE"; then
                ok "WYN Agent is running!"
            else
                warn "Agent may have failed. Check: journalctl -u $SERVICE -n 30"
            fi
        fi
    else
        echo ""
        info "To start manually (requires root):"
        echo "    sudo python3 $INSTALL_DIR/agent.py --config $CONFIG_DIR/agent.conf"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Agent installation complete!${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "  ${CYAN}Node   →  $NODE_NAME  ($NODE_ID)${NC}"
    echo -e "  ${CYAN}Server →  ws://${SERVER_HOST}:${AGENT_PORT}${NC}"
    echo -e "  ${CYAN}Iface  →  $IFACE${NC}"
    echo ""
}

main "$@"
