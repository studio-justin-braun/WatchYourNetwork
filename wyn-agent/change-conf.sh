#!/usr/bin/env bash
# WatchYourNetwork — Agent Config Editor
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

CONFIG="${1:-/etc/wyn/agent.conf}"
SERVICE="wyn-agent"

ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${CYAN}  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
sep()  { echo -e "${BLUE}────────────────────────────────────────${NC}"; }

# ── YAML helpers (via Python) ──────────────────────────────────────────────────

yaml_get() {
    python3 -c "
import yaml, sys
with open('$CONFIG') as f: cfg = yaml.safe_load(f)
keys = '$1'.split('.')
v = cfg
for k in keys:
    v = v.get(k, '')
if isinstance(v, list): print(', '.join(str(x) for x in v))
else: print(v if v is not None else '')
" 2>/dev/null || echo ""
}

yaml_set() {
    local keypath="$1" value="$2"
    python3 - "$CONFIG" "$keypath" "$value" <<'PYEOF'
import yaml, sys
path, keypath, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    cfg = yaml.safe_load(f)
keys = keypath.split('.')
obj = cfg
for k in keys[:-1]:
    obj = obj.setdefault(k, {})
last = keys[-1]
# Type coercion
if value.lower() == 'true':  obj[last] = True
elif value.lower() == 'false': obj[last] = False
elif value.isdigit(): obj[last] = int(value)
else: obj[last] = value
with open(path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF
}

yaml_set_list() {
    local keypath="$1"; shift
    local items=("$@")
    python3 - "$CONFIG" "$keypath" "${items[@]}" <<'PYEOF'
import yaml, sys
path, keypath, *items = sys.argv[1:]
with open(path) as f:
    cfg = yaml.safe_load(f)
keys = keypath.split('.')
obj = cfg
for k in keys[:-1]:
    obj = obj.setdefault(k, {})
obj[keys[-1]] = items
with open(path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF
}

# ── Show current values ────────────────────────────────────────────────────────

show_config() {
    sep
    echo -e "  ${BOLD}Config: $CONFIG${NC}"
    sep
    printf "  %-28s %s\n" "Server:" "$(yaml_get server.host):$(yaml_get server.port)"
    printf "  %-28s %s\n" "Node ID:" "$(yaml_get node.id)"
    printf "  %-28s %s\n" "Node name:" "$(yaml_get node.name)"
    printf "  %-28s %s\n" "Interfaces:" "$(yaml_get capture.interfaces)"
    local bpf; bpf=$(yaml_get capture.bpf_filter)
    printf "  %-28s %s\n" "BPF filter:" "${bpf:-(none — all traffic)}"
    local track; track=$(yaml_get capture.track_processes)
    if [[ "$track" == "True" || "$track" == "true" ]]; then
        printf "  %-28s %b\n" "App tracking:" "${GREEN}enabled — nginx/flask/… shown in UI${NC}"
    else
        printf "  %-28s %b\n" "App tracking:" "${YELLOW}disabled${NC}"
    fi
    printf "  %-28s %s\n" "Ignore loopback:" "$(yaml_get capture.ignore_loopback)"
    printf "  %-28s %s\n" "Batch interval (ms):" "$(yaml_get report.batch_interval_ms)"
    sep
}

# ── Restart service ────────────────────────────────────────────────────────────

restart_service() {
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        echo -e "${YELLOW}Restarting $SERVICE …${NC}"
        systemctl restart "$SERVICE"
        sleep 1
        if systemctl is-active --quiet "$SERVICE"; then
            ok "Service restarted"
        else
            warn "Service may have failed — check: journalctl -u $SERVICE -n 20"
        fi
    else
        warn "Service '$SERVICE' is not running. Start with: systemctl start $SERVICE"
    fi
}

# ── BPF filter menu ────────────────────────────────────────────────────────────

set_bpf_filter() {
    echo ""
    echo -e "${BOLD}BPF Filter Presets${NC}"
    echo ""
    echo "  [0]  No filter          (all traffic — may be noisy)"
    echo "  [1]  Web only           port 80 or port 443"
    echo "  [2]  Web + SSH          port 22 or port 80 or port 443"
    echo "  [3]  No WireGuard       not port 51820"
    echo "  [4]  No WG + no DNS     not port 51820 and not port 53"
    echo "  [5]  No WG + no DHCP    not port 51820 and not port 53 and not port 67"
    echo "  [6]  Services only      port 22 or port 80 or port 443 or port 3306 or port 5432 or port 6379"
    echo "  [7]  WireGuard only     port 51820"
    echo "  [8]  Custom BPF expression…"
    echo ""
    local current; current=$(yaml_get capture.bpf_filter)
    info "Current: ${current:-(none)}"
    echo ""
    local choice
    read -rp "  Choose [0-8]: " choice

    local new_filter=""
    case "$choice" in
        0) new_filter="" ;;
        1) new_filter="port 80 or port 443" ;;
        2) new_filter="port 22 or port 80 or port 443" ;;
        3) new_filter="not port 51820" ;;
        4) new_filter="not port 51820 and not port 53" ;;
        5) new_filter="not port 51820 and not port 53 and not port 67" ;;
        6) new_filter="port 22 or port 80 or port 443 or port 3306 or port 5432 or port 6379" ;;
        7) new_filter="port 51820" ;;
        8)
            read -rp "  Enter BPF expression: " new_filter
            ;;
        *) warn "Invalid choice"; return ;;
    esac

    yaml_set capture.bpf_filter "$new_filter"
    ok "BPF filter set to: ${new_filter:-(none)}"
}

# ── Interface selection ────────────────────────────────────────────────────────

set_interfaces() {
    echo ""
    echo -e "${BOLD}Available network interfaces:${NC}"
    declare -A IF_MAP=()
    local idx=1
    while IFS= read -r iface; do
        local ip4
        ip4=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\S+' | head -1 || true)
        printf "  %2d)  %-22s %s\n" "$idx" "$iface" "${ip4:-(no IPv4)}"
        IF_MAP[$idx]="$iface"
        ((idx++))
    done < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^lo$')
    echo ""
    info "Current: $(yaml_get capture.interfaces)"
    echo -e "  ${CYAN}Enter numbers or names (space-separated, e.g.: 1 3  or  ens6 wg0)${NC}"
    echo ""
    local choice
    read -rp "  Interfaces [keep current — press Enter]: " choice
    [[ -z "$choice" ]] && return

    local selected=()
    for token in $choice; do
        if [[ "$token" =~ ^[0-9]+$ ]] && [[ -n "${IF_MAP[$token]+x}" ]]; then
            selected+=("${IF_MAP[$token]}")
        else
            selected+=("$token")
        fi
    done
    [[ ${#selected[@]} -eq 0 ]] && { warn "No interfaces selected"; return; }
    yaml_set_list capture.interfaces "${selected[@]}"
    ok "Interfaces set to: ${selected[*]}"
}

# ── Process tracking ───────────────────────────────────────────────────────────

set_process_tracking() {
    local current; current=$(yaml_get capture.track_processes)
    echo ""
    info "Current: $current"
    echo ""
    echo "  When enabled, packets are annotated with the originating application"
    echo "  (e.g. nginx, python3, flask, sshd, curl)."
    echo ""
    echo "  The browser UI will:"
    echo "    • Show a colored label on each connection line (e.g. 'nginx')"
    echo "    • Color packet dots per application"
    echo "    • Show a filter panel to hide/show traffic by app"
    echo ""
    echo "  Requires root / CAP_NET_ADMIN. Adds small CPU overhead (~0.5% extra)."
    echo ""
    echo "  [1] Enable   (show app names in UI)"
    echo "  [2] Disable  (all traffic shown as generic dots)"
    echo ""
    local choice
    read -rp "  Choose [1/2]: " choice
    case "$choice" in
        1) yaml_set capture.track_processes true;  ok "App tracking enabled — restart agent to apply" ;;
        2) yaml_set capture.track_processes false; ok "App tracking disabled — restart agent to apply" ;;
        *) warn "No change" ;;
    esac
}

# ── Main menu ──────────────────────────────────────────────────────────────────

main() {
    if [[ ! -f "$CONFIG" ]]; then
        echo -e "${RED}Config not found: $CONFIG${NC}"
        echo "Usage: $0 [/path/to/agent.conf]"
        exit 1
    fi

    while true; do
        clear
        echo ""
        echo -e "${BLUE}${BOLD}  WYN Agent — Config Editor${NC}"
        show_config
        echo ""
        echo -e "  ${BOLD}[1]${NC}  Change server host / port"
        echo -e "  ${BOLD}[2]${NC}  Change node ID / display name"
        echo -e "  ${BOLD}[3]${NC}  Change capture interfaces"
        echo -e "  ${BOLD}[4]${NC}  Set BPF traffic filter  ${CYAN}(reduce noise)${NC}"
        echo -e "  ${BOLD}[5]${NC}  Toggle app tracking      ${CYAN}(nginx/flask labels + filter in UI)${NC}"
        echo -e "  ${BOLD}[6]${NC}  Set batch interval"
        echo -e "  ${BOLD}[r]${NC}  Restart agent service"
        echo -e "  ${BOLD}[q]${NC}  Quit"
        echo ""
        local choice
        read -rp "  Choose: " choice

        case "$choice" in
            1)
                echo ""
                local cur_host; cur_host=$(yaml_get server.host)
                local cur_port; cur_port=$(yaml_get server.port)
                read -rp "  Server host [$cur_host]: " new_host
                read -rp "  Server port [$cur_port]: " new_port
                [[ -n "$new_host" ]] && yaml_set server.host "$new_host" && ok "Host set to $new_host"
                [[ -n "$new_port" ]] && yaml_set server.port "$new_port" && ok "Port set to $new_port"
                read -rp "  Press Enter to continue…" _
                ;;
            2)
                echo ""
                local cur_id; cur_id=$(yaml_get node.id)
                local cur_name; cur_name=$(yaml_get node.name)
                read -rp "  Node ID   [$cur_id]: " new_id
                read -rp "  Node name [$cur_name]: " new_name
                [[ -n "$new_id" ]]   && yaml_set node.id   "$new_id"   && ok "ID set to $new_id"
                [[ -n "$new_name" ]] && yaml_set node.name "$new_name" && ok "Name set to $new_name"
                read -rp "  Press Enter to continue…" _
                ;;
            3)
                set_interfaces
                read -rp "  Press Enter to continue…" _
                ;;
            4)
                set_bpf_filter
                read -rp "  Press Enter to continue…" _
                ;;
            5)
                set_process_tracking
                read -rp "  Press Enter to continue…" _
                ;;
            6)
                echo ""
                local cur_ms; cur_ms=$(yaml_get report.batch_interval_ms)
                info "Current batch interval: ${cur_ms}ms  (lower = smoother UI, higher = less CPU)"
                read -rp "  New value in ms [$cur_ms]: " new_ms
                [[ -n "$new_ms" ]] && yaml_set report.batch_interval_ms "$new_ms" && ok "Interval set to ${new_ms}ms"
                read -rp "  Press Enter to continue…" _
                ;;
            r|R)
                restart_service
                read -rp "  Press Enter to continue…" _
                ;;
            q|Q)
                echo ""
                echo -e "${GREEN}Done. Config saved at $CONFIG${NC}"
                echo ""
                exit 0
                ;;
            *)
                warn "Unknown option"
                sleep 0.5
                ;;
        esac
    done
}

main "$@"
