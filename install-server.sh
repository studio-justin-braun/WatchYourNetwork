#!/usr/bin/env bash
# WatchYourNetwork — Server Installer
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/wyn-server"
CONFIG_DIR="/etc/wyn"
SERVICE="wyn-server"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/wyn-server"
UI_DIR="$SCRIPT_DIR/wyn-ui"

# ── Helpers ────────────────────────────────────────────────────────────────────

ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${CYAN}  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "${RED}✗ $*${NC}"; exit 1; }
ask()  { local prompt="$1" default="$2" var="$3"; read -rp "  $prompt [$default]: " "$var"; eval "$var=\"\${$var:-$default}\""; }

banner() {
echo -e "${BLUE}"
cat <<'EOF'
  ██╗    ██╗ █████╗ ████████╗ ██████╗██╗  ██╗██╗   ██╗ ██████╗ ██╗   ██╗██████╗
  ██║    ██║██╔══██╗╚══██╔══╝██╔════╝██║  ██║╚██╗ ██╔╝██╔═══██╗██║   ██║██╔══██╗
  ██║ █╗ ██║███████║   ██║   ██║     ███████║ ╚████╔╝ ██║   ██║██║   ██║██████╔╝
  ██║███╗██║██╔══██║   ██║   ██║     ██╔══██║  ╚██╔╝  ██║   ██║██║   ██║██╔══██╗
  ╚███╔███╔╝██║  ██║   ██║   ╚██████╗██║  ██║   ██║   ╚██████╔╝╚██████╔╝██║  ██║
   ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝  ╚═════╝ ╚═╝  ╚═╝
EOF
echo -e "${NC}${CYAN}  WatchYourNetwork — Server Installer${NC}"
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

# ── Python check / install ─────────────────────────────────────────────────────

ensure_python() {
    if command -v python3 &>/dev/null; then
        local ver
        ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        local major minor
        major="${ver%%.*}"; minor="${ver##*.}"
        if [[ $major -ge 3 && $minor -ge 10 ]]; then
            ok "Python $ver found"
            return
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
        *)       die "Cannot install Python automatically. Please install Python 3.10+ manually." ;;
    esac
    ok "Python installed"
}

# ── pip: detect or install ─────────────────────────────────────────────────────

PIP_CMD=""

ensure_pip() {
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

    if python3 -m pip --version &>/dev/null 2>&1; then
        PIP_CMD="python3 -m pip"
    elif command -v pip3 &>/dev/null; then
        PIP_CMD="pip3"
    else
        die "pip install failed. Run manually: ${PKG_MANAGER} install python3-pip"
    fi
    ok "pip installed"
}

pip_install() {
    local req="$1"
    local flags=""
    if $PIP_CMD install --help 2>/dev/null | grep -q "break-system-packages"; then
        flags="--break-system-packages --ignore-installed"
    fi
    echo -e "${YELLOW}Installing Python packages…${NC}"
    $PIP_CMD install $flags -r "$req"
    ok "Python packages installed"
}

# ── Port configuration ─────────────────────────────────────────────────────────

configure_ports() {
    echo ""
    echo -e "${BOLD}Port Configuration${NC}  (press Enter to keep defaults)"
    echo ""
    ask "Web UI + WebSocket port" "8080" HTTP_PORT
    ask "Agent WebSocket port   " "8765" AGENT_PORT

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")
    echo ""
    info "Web UI will be at  →  http://${ip}:${HTTP_PORT}"
    info "Agents connect to  →  ws://${ip}:${AGENT_PORT}"
    echo ""
}

# ── Write config ───────────────────────────────────────────────────────────────

write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/server.yaml" <<EOF
server:
  http_port: ${HTTP_PORT}
  agent_port: ${AGENT_PORT}

topology:
  connection_ttl: 1800
  node_colors: {}

internet_node:
  label: "Internet"
  color: "#95A5A6"

logging:
  level: INFO
EOF
    ok "Config written to $CONFIG_DIR/server.yaml"
}

# ── Install files ──────────────────────────────────────────────────────────────

install_files() {
    mkdir -p "$INSTALL_DIR"
    cp "$SERVER_DIR/server.py"       "$INSTALL_DIR/"
    cp "$SERVER_DIR/requirements.txt" "$INSTALL_DIR/"

    if [[ -d "$UI_DIR" ]]; then
        cp -r "$UI_DIR" "$INSTALL_DIR/wyn-ui"
        ok "UI files copied"
    else
        warn "wyn-ui directory not found — UI will not be served"
    fi

    ok "Server files installed to $INSTALL_DIR"
}

# ── wyn CLI ────────────────────────────────────────────────────────────────────

install_wyn_cli() {
    local wyn_src="$SCRIPT_DIR/wyn-ctl/wyn"
    if [[ ! -f "$wyn_src" ]]; then
        warn "wyn CLI not found at $wyn_src — skipping"
        return
    fi
    cp "$wyn_src" /usr/local/bin/wyn
    chmod +x /usr/local/bin/wyn
    ok "wyn CLI installed → /usr/local/bin/wyn"
    info "  Try: wyn status | wyn logs | wyn update | wyn --help"
}

# ── systemd service ────────────────────────────────────────────────────────────

install_service() {
    cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=WatchYourNetwork Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v python3) $INSTALL_DIR/server.py --config $CONFIG_DIR/server.yaml --ui-dir $INSTALL_DIR/wyn-ui
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=5
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
    ensure_pip
    configure_ports
    write_config
    pip_install "$SERVER_DIR/requirements.txt"
    install_files
    install_wyn_cli

    echo ""
    local install_svc
    ask "Install as systemd service?" "y" install_svc
    if [[ "${install_svc,,}" == "y" ]]; then
        install_service

        local start_now
        ask "Start WYN Server now?" "y" start_now
        if [[ "${start_now,,}" == "y" ]]; then
            systemctl start "$SERVICE"
            sleep 1
            if systemctl is-active --quiet "$SERVICE"; then
                ok "WYN Server is running!"
            else
                warn "Server may have failed. Check: journalctl -u $SERVICE -n 30"
            fi
        fi
    else
        echo ""
        info "To start manually:"
        echo "    python3 $INSTALL_DIR/server.py --config $CONFIG_DIR/server.yaml"
    fi

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")
    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "  ${CYAN}Web UI   →  http://${ip}:${HTTP_PORT}${NC}"
    echo -e "  ${CYAN}Agents   →  ws://${ip}:${AGENT_PORT}${NC}"
    echo ""
    echo -e "  ${BOLD}wyn CLI commands:${NC}"
    echo "    wyn status            Show service status"
    echo "    wyn restart           Restart server + agent"
    echo "    wyn logs              Show server logs"
    echo "    wyn update            Update to latest version"
    echo "    wyn uninstall         Remove installation"
    echo ""
}

main "$@"
