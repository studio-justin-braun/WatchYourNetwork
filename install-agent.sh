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

PIP_CMD=""
declare -g -a SELECTED_IFACES=()

# ── Helpers ────────────────────────────────────────────────────────────────────

ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${CYAN}  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}"; exit 1; }
ask()  {
    local prompt="$1" default="$2" var="$3"
    read -rp "  $prompt [$default]: " "$var"
    eval "$var=\"\${$var:-$default}\""
}

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
        warn "Python $ver is too old (need 3.10+)"
    fi

    echo -e "${YELLOW}Installing Python 3.10+…${NC}"
    case "$PKG_MANAGER" in
        apt)     apt-get install -y python3 python3-dev ;;
        dnf)     dnf install -y python3 ;;
        yum)     yum install -y python3 ;;
        pacman)  pacman -Sy --noconfirm python ;;
        apk)     apk add --no-cache python3 ;;
        zypper)  zypper install -y python3 ;;
        *)       die "Install Python 3.10+ manually, then re-run." ;;
    esac
    ok "Python installed"
}

# ── pip: detect or install ─────────────────────────────────────────────────────

ensure_pip() {
    # Prefer python3 -m pip — always tied to the correct interpreter
    if python3 -m pip --version &>/dev/null 2>&1; then
        PIP_CMD="python3 -m pip"; ok "pip found (python3 -m pip)"; return
    fi
    if command -v pip3 &>/dev/null; then
        PIP_CMD="pip3"; ok "pip3 found"; return
    fi

    echo -e "${YELLOW}pip not found — installing…${NC}"
    case "$PKG_MANAGER" in
        apt)     apt-get install -y python3-pip ;;
        dnf)     dnf install -y python3-pip ;;
        yum)     yum install -y python3-pip ;;
        pacman)  pacman -S --noconfirm python-pip ;;
        apk)     apk add --no-cache py3-pip ;;
        zypper)  zypper install -y python3-pip ;;
        *)       python3 -m ensurepip --upgrade 2>/dev/null \
                     || die "Cannot install pip. Run: apt install python3-pip" ;;
    esac

    # Re-check after install
    if python3 -m pip --version &>/dev/null 2>&1; then
        PIP_CMD="python3 -m pip"
    elif command -v pip3 &>/dev/null; then
        PIP_CMD="pip3"
    else
        die "pip install failed. Run manually: ${PKG_MANAGER} install python3-pip"
    fi
    ok "pip installed"
}

# ── pip package install (no venv) ──────────────────────────────────────────────

pip_install() {
    local req="$1"
    local flags=""
    # PEP 668: modern Debian/Ubuntu block system-wide pip installs
    if $PIP_CMD install --help 2>/dev/null | grep -q "break-system-packages"; then
        flags="--break-system-packages --ignore-installed"
    fi
    echo -e "${YELLOW}Installing Python packages…${NC}"
    $PIP_CMD install $flags -r "$req"
    ok "Python packages installed"
}

# ── Interface selection (multi) ────────────────────────────────────────────────

choose_interfaces() {
    echo ""
    echo -e "${BOLD}Available network interfaces:${NC}"

    declare -g -A IF_MAP=()
    local idx=1
    while IFS= read -r iface; do
        local ip4
        ip4=$(ip -4 addr show "$iface" 2>/dev/null \
              | grep -oP '(?<=inet\s)\S+' | head -1 || true)
        printf "  %2d)  %-22s %s\n" "$idx" "$iface" "${ip4:-(no IPv4)}"
        IF_MAP[$idx]="$iface"
        ((idx++))
    done < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^lo$')
    echo ""

    echo -e "  ${CYAN}Enter numbers or names separated by spaces.${NC}"
    echo -e "  ${CYAN}Examples:  1          →  first interface only${NC}"
    echo -e "  ${CYAN}           1 6        →  interfaces 1 and 6${NC}"
    echo -e "  ${CYAN}           ens6 wg0   →  by name${NC}"
    echo ""
    local choice
    read -rp "  Interfaces to monitor [1]: " choice
    choice="${choice:-1}"

    SELECTED_IFACES=()
    for token in $choice; do
        if [[ "$token" =~ ^[0-9]+$ ]] && [[ -n "${IF_MAP[$token]+x}" ]]; then
            SELECTED_IFACES+=("${IF_MAP[$token]}")
        elif [[ -n "$token" ]]; then
            SELECTED_IFACES+=("$token")
        fi
    done

    [[ ${#SELECTED_IFACES[@]} -eq 0 ]] && die "No interfaces selected."
    ok "Selected: ${SELECTED_IFACES[*]}"
}

# ── Agent configuration ────────────────────────────────────────────────────────

configure_agent() {
    local default_hostname
    default_hostname=$(hostname -s)

    echo ""
    echo -e "${BOLD}WYN Server Connection${NC}"
    echo ""

    local server_input
    read -rp "  WYN Server IP or hostname: " server_input
    [[ -z "$server_input" ]] && die "Server IP/hostname is required."
    SERVER_HOST="$server_input"

    ask "WYN Server agent port" "8765" AGENT_PORT

    echo ""
    echo -e "${BOLD}Node Identity${NC}"
    echo ""
    ask "Node ID  (unique, no spaces)" "$default_hostname" NODE_ID
    ask "Node display name" "$default_hostname" NODE_NAME

    choose_interfaces

    echo ""
    echo -e "${CYAN}  Summary:${NC}"
    info "Server   →  ${SERVER_HOST}:${AGENT_PORT}"
    info "Node ID  →  $NODE_ID  ($NODE_NAME)"
    info "Ifaces   →  ${SELECTED_IFACES[*]}"
    echo ""
}

# ── Write config ───────────────────────────────────────────────────────────────

write_config() {
    mkdir -p "$CONFIG_DIR"

    # Build YAML interface list
    local iface_lines=""
    for iface in "${SELECTED_IFACES[@]}"; do
        iface_lines+="    - ${iface}"$'\n'
    done

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
${iface_lines}  bpf_filter: ""
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
    cp "$AGENT_DIR/agent.py"          "$INSTALL_DIR/"
    cp "$AGENT_DIR/requirements.txt"  "$INSTALL_DIR/"
    ok "Agent files installed to $INSTALL_DIR"
}

# ── systemd service ────────────────────────────────────────────────────────────

install_service() {
    local py3
    py3=$(command -v python3)
    cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=WatchYourNetwork Agent (${NODE_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${py3} $INSTALL_DIR/agent.py --config $CONFIG_DIR/agent.conf
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

    [[ $EUID -ne 0 ]] && die "Run with sudo: sudo bash $0"

    detect_os
    echo ""
    ensure_python
    ensure_pip
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
    echo -e "  ${CYAN}Node    →  $NODE_NAME  ($NODE_ID)${NC}"
    echo -e "  ${CYAN}Server  →  ws://${SERVER_HOST}:${AGENT_PORT}${NC}"
    echo -e "  ${CYAN}Ifaces  →  ${SELECTED_IFACES[*]}${NC}"
    echo ""
}

main "$@"
