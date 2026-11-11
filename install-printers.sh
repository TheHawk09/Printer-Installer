#!/usr/bin/env bash
# ===============================================================================
# ENTERPRISE NETWORK PRINTER MANAGER FOR LINUX (CUPS)
# Deployment, Diagnostic, and Management Engine for GTG Copiers
# Compatible with Arch Linux, NixOS, Debian, Ubuntu, Fedora, openSUSE & RHEL
# ===============================================================================

set -u
trap 'echo -e "\n\033[0mOperation canceled by user."; exit 130' INT TERM

# Ensure UTF-8 locale for Unicode box-drawing characters
if [ -z "${LANG:-}" ] || [[ "$LANG" != *"UTF-8"* && "$LANG" != *"utf8"* ]]; then
    export LANG="C.UTF-8"
fi

# Start execution stopwatch for telemetry
START_TIME=$(date +%s%N 2>/dev/null || date +%s)

# Default parameter values
PRINT_SERVER="gtcps001.gtc.local"
FALLBACK_IP="172.16.0.32"
INTERNAL_DNS_SERVERS=("172.16.0.7" "172.16.0.8")
PRINTERS=("L-Kopiator" "TB-Kopiator" "PB-Kopiator")
DEFAULT_PRINTER=""
PRINT_FILE=""
PRINT_TEST_PAGE=false
START_PAPERCUT=false
DUPLEX_MODE=true
UNINSTALL_MODE=false
LIST_INSTALLED_MODE=false
LIST_AVAILABLE_MODE=false
RESTART_CUPS_MODE=false
MENU_MODE=false
SHOW_LOG_MODE=false
FORCE_INSTALL=false
NO_PAUSE=false

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LOG_DIR="$XDG_DATA_HOME/GTG-Printers"
LOG_FILE="$LOG_DIR/PrinterInstaller.log"
MAX_LOG_SIZE_BYTES=$((2 * 1024 * 1024)) # 2 MB

# Box-drawing Unicode symbols
BOX_D_TL="╔"; BOX_D_TR="╗"; BOX_D_BL="╚"; BOX_D_BR="╝"; BOX_D_H="═"; BOX_D_V="║"; BOX_D_LT="╠"; BOX_D_RT="╣"
BOX_S_TL="┌"; BOX_S_TR="┐"; BOX_S_BL="└"; BOX_S_BR="┘"; BOX_S_H="─"; BOX_S_V="│"; BOX_S_LT="├"; BOX_S_RT="┤"
BOX_CHECK="✔"; BOX_CROSS="✘"; BOX_ARROW="▸"; BLOCK_FULL="█"; BLOCK_LIGHT="░"

MIN_TUI_WIDTH=75
MAX_TUI_WIDTH=100
CURRENT_TUI_WIDTH=$MIN_TUI_WIDTH

# Color definitions
COLOR_RESET="\033[0m"
COLOR_CYAN="\033[36m"
COLOR_DARKCYAN="\033[36;2m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_WHITE="\033[37;1m"
COLOR_GRAY="\033[90m"

# -------------------------------------------------------------
# PRE-FLIGHT INPUT VALIDATION & SECURITY (CWE-20 / CWE-200 / CWE-300)
# -------------------------------------------------------------
is_private_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 1; fi
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then return 1; fi
    if (( o1 == 127 )); then return 0; fi               # Loopback
    if (( o1 == 10 )); then return 0; fi                # 10.0.0.0/8
    if (( o1 == 172 && o2 >= 16 && o2 <= 31 )); then return 0; fi # 172.16.0.0/12
    if (( o1 == 192 && o2 == 168 )); then return 0; fi # 192.168.0.0/16
    if (( o1 == 169 && o2 == 254 )); then return 0; fi # 169.254.0.0/16
    return 1
}

validate_input_params() {
    local re_server='^[a-zA-Z0-9_.-]+$'
    local re_ip='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    local re_printer='^[a-zA-Z0-9_ -]+$'

    # Sanitize server prefix/suffix
    PRINT_SERVER="${PRINT_SERVER#\\\\}"
    PRINT_SERVER="${PRINT_SERVER#/}"
    PRINT_SERVER="${PRINT_SERVER%\\}"
    PRINT_SERVER="${PRINT_SERVER%/}"

    if [ -n "$PRINT_SERVER" ] && [[ ! "$PRINT_SERVER" =~ $re_server ]]; then
        echo -e "${COLOR_RED}Invalid characters in print server hostname: '$PRINT_SERVER'${COLOR_RESET}" >&2
        exit 1
    fi
    if [ -n "$FALLBACK_IP" ]; then
        if [[ ! "$FALLBACK_IP" =~ $re_ip ]]; then
            echo -e "${COLOR_RED}Invalid IP address format in fallback IP: '$FALLBACK_IP'${COLOR_RESET}" >&2
            exit 1
        fi
        if ! is_private_ip "$FALLBACK_IP"; then
            echo -e "${COLOR_RED}Security Policy Violation (CWE-200/CWE-300): Fallback IP '$FALLBACK_IP' is a public IP. Targets must reside in private RFC 1918 subnets.${COLOR_RESET}" >&2
            exit 1
        fi
    fi
    for dns in "${INTERNAL_DNS_SERVERS[@]}"; do
        if [[ ! "$dns" =~ $re_ip ]] || ! is_private_ip "$dns"; then
            echo -e "${COLOR_RED}Security Policy Violation: Internal DNS server '$dns' must be a valid private RFC 1918 address.${COLOR_RESET}" >&2
            exit 1
        fi
    done
    for p in "${PRINTERS[@]}"; do
        if [[ ! "$p" =~ $re_printer ]]; then
            echo -e "${COLOR_RED}Invalid characters in printer name: '$p'${COLOR_RESET}" >&2
            exit 1
        fi
    done
    if [ -n "$DEFAULT_PRINTER" ] && [[ ! "$DEFAULT_PRINTER" =~ $re_printer ]]; then
        echo -e "${COLOR_RED}Invalid characters in default printer name: '$DEFAULT_PRINTER'${COLOR_RESET}" >&2
        exit 1
    fi
}

# -------------------------------------------------------------
# LOGGING & ROTATION ENGINE (CWE-59 / CWE-367 / CWE-732)
# -------------------------------------------------------------
init_logger() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        chmod 700 "$LOG_DIR" 2>/dev/null || true
    fi
}

rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        # Defend against symlink traversal attacks (CWE-59)
        if [ -L "$LOG_FILE" ]; then return 0; fi
        local file_size
        file_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if (( file_size > MAX_LOG_SIZE_BYTES )); then
            local archive="$LOG_FILE.old"
            if [ -L "$archive" ]; then rm -f "$archive" 2>/dev/null || true; fi
            mv -f "$LOG_FILE" "$archive" 2>/dev/null || true
        fi
    fi
}

write_log() {
    local msg="$1"
    local color="${2:-$COLOR_RESET}"
    local no_newline="${3:-false}"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    init_logger
    rotate_log_if_needed

    # Check if target is a symlink before appending (CWE-59)
    if [ ! -L "$LOG_FILE" ]; then
        echo "[$timestamp] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi

    if [ "$no_newline" = true ]; then
        echo -en "${color}${msg}${COLOR_RESET}"
    else
        echo -e "${color}${msg}${COLOR_RESET}"
    fi
}

# -------------------------------------------------------------
# TUI VISUAL BUILDERS
# -------------------------------------------------------------
get_progress_bar_string() {
    local percent="$1"
    local width="${2:-20}"
    if (( percent < 0 )); then percent=0; fi
    if (( percent > 100 )); then percent=100; fi
    local filled=$(( (percent * width + 50) / 100 ))
    local empty=$(( width - filled ))
    local fill_str=""
    local empty_str=""
    for (( i=0; i<filled; i++ )); do fill_str+="$BLOCK_FULL"; done
    for (( i=0; i<empty; i++ )); do empty_str+="$BLOCK_LIGHT"; done
    printf "%s%s %3d%%" "$fill_str" "$empty_str" "$percent"
}

get_dynamic_width() {
    local max_len=$MIN_TUI_WIDTH
    for line in "$@"; do
        local len=${#line}
        if (( len + 6 > max_len )); then
            max_len=$(( len + 6 ))
        fi
    done
    if (( max_len > MAX_TUI_WIDTH )); then
        echo $MAX_TUI_WIDTH
    else
        echo $max_len
    fi
}

repeat_char() {
    local char="$1"
    local count="$2"
    local out=""
    for (( i=0; i<count; i++ )); do out+="$char"; done
    echo "$out"
}

show_box_title() {
    local title="$1"; shift
    local lines=("$@")
    local w
    w=$(get_dynamic_width "$title" "${lines[@]}")
    CURRENT_TUI_WIDTH=$w
    local inner_w=$(( w - 2 ))
    local h_line
    h_line=$(repeat_char "$BOX_D_H" "$inner_w")

    write_log "${BOX_D_TL}${h_line}${BOX_D_TR}" "$COLOR_CYAN"
    local t_len=${#title}
    local left_pad=$(( (inner_w - t_len) / 2 ))
    local right_pad=$(( inner_w - t_len - left_pad ))
    write_log "${BOX_D_V}$(repeat_char " " "$left_pad")${title}$(repeat_char " " "$right_pad")${BOX_D_V}" "$COLOR_CYAN"

    if (( ${#lines[@]} > 0 )); then
        write_log "${BOX_D_LT}${h_line}${BOX_D_RT}" "$COLOR_CYAN"
        for line in "${lines[@]}"; do
            local l_len=${#line}
            local line_pad=$(( inner_w - l_len - 2 ))
            if (( line_pad < 0 )); then line_pad=0; fi
            write_log "${BOX_D_V} ${line}$(repeat_char " " "$line_pad") ${BOX_D_V}" "$COLOR_DARKCYAN"
        done
    fi
    write_log "${BOX_D_BL}${h_line}${BOX_D_BR}" "$COLOR_CYAN"
}

show_section_header() {
    local title="$1"
    local color="${2:-$COLOR_CYAN}"
    local w=$CURRENT_TUI_WIDTH
    local inner_w=$(( w - 2 ))
    local h_line
    h_line=$(repeat_char "$BOX_S_H" "$inner_w")

    write_log ""
    write_log "${BOX_S_TL}${h_line}${BOX_S_TR}" "$color"
    local t_len=${#title}
    local pad=$(( inner_w - t_len - 2 ))
    if (( pad < 0 )); then pad=0; fi
    write_log "${BOX_S_V} ${title}$(repeat_char " " "$pad") ${BOX_S_V}" "$color"
    write_log "${BOX_S_BL}${h_line}${BOX_S_BR}" "$color"
}

show_notice_box() {
    local header="$1"; shift
    local color="${1:-$COLOR_YELLOW}"; shift
    local lines=("$@")
    local w
    w=$(get_dynamic_width "$header" "${lines[@]}")
    local inner_w=$(( w - 2 ))
    local h_line
    h_line=$(repeat_char "$BOX_S_H" "$inner_w")

    write_log ""
    write_log "${BOX_S_TL}${h_line}${BOX_S_TR}" "$color"
    local h_len=${#header}
    local h_pad=$(( inner_w - h_len - 2 ))
    if (( h_pad < 0 )); then h_pad=0; fi
    write_log "${BOX_S_V} ${header}$(repeat_char " " "$h_pad") ${BOX_S_V}" "$color"
    write_log "${BOX_S_LT}${h_line}${BOX_S_RT}" "$color"
    for line in "${lines[@]}"; do
        local l_len=${#line}
        local pad=$(( inner_w - l_len - 2 ))
        if (( pad < 0 )); then pad=0; fi
        write_log "${BOX_S_V} ${line}$(repeat_char " " "$pad") ${BOX_S_V}" "$color"
    done
    write_log "${BOX_S_BL}${h_line}${BOX_S_BR}" "$color"
}

# -------------------------------------------------------------
# DISTRO & ENVIRONMENT DETECTION
# -------------------------------------------------------------
detect_distro() {
    IS_NIXOS=false
    IS_OSTREE=false

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${NAME:-Linux}"
        DISTRO_LIKE="${ID_LIKE:-}"
    else
        DISTRO_ID="unknown"
        DISTRO_NAME="Generic Linux"
        DISTRO_LIKE=""
    fi

    if [ -f /etc/NIXOS ] || [ "$DISTRO_ID" = "nixos" ]; then
        DISTRO_ID="nixos"
        DISTRO_NAME="NixOS"
        IS_NIXOS=true
    fi

    if [ -f /run/ostree-booted ] || [ -d /sys/fs/ostree ]; then
        IS_OSTREE=true
    fi
}

check_printer_group() {
    local required_group="lpadmin"
    case "$DISTRO_ID" in
        debian|ubuntu|linuxmint|pop) required_group="lpadmin" ;;
        arch|manjaro|endeavouros)   required_group="lp" ;;
        fedora|rhel|centos|rocky)   required_group="wheel" ;;
        opensuse*|suse)             required_group="lp" ;;
        *)                          required_group="lpadmin" ;;
    esac

    write_log "  $BOX_ARROW User Group ($required_group)   : " "$COLOR_WHITE" true
    if id -nG 2>/dev/null | grep -qw "$required_group" || [ "${EUID:-$(id -u)}" -eq 0 ]; then
        write_log "MEMBER $BOX_CHECK" "$COLOR_GREEN"
    else
        write_log "NOT MEMBER (Requires sudo) $BOX_CROSS" "$COLOR_YELLOW"
    fi
}

get_active_ssid() {
    local ssid=""
    if command -v nmcli >/dev/null 2>&1; then
        ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2 | head -n1 || true)
    fi
    if [ -z "$ssid" ] && command -v iwgetid >/dev/null 2>&1; then
        ssid=$(iwgetid -r 2>/dev/null || true)
    fi
    if [ -z "$ssid" ] && [ -d /sys/class/net ]; then
        for iface in /sys/class/net/*; do
            local ifname
            ifname=$(basename "$iface")
            if [ "$ifname" != "lo" ] && [ -f "$iface/operstate" ]; then
                if [ "$(cat "$iface/operstate" 2>/dev/null)" = "up" ]; then
                    ssid="Ethernet ($ifname)"
                    break
                fi
            fi
        done
    fi
    echo "${ssid:-Disconnected / Unknown}"
}

# -------------------------------------------------------------
# PAPERCUT MF CLIENT UTILITIES
# -------------------------------------------------------------
get_papercut_status() {
    local pid=""
    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -x pc-client 2>/dev/null | head -n1 || true)
        if [ -z "$pid" ]; then
            pid=$(pgrep -f "pc-client" 2>/dev/null | head -n1 || true)
        fi
    elif command -v pidof >/dev/null 2>&1; then
        pid=$(pidof pc-client 2>/dev/null | awk '{print $1}' || true)
    fi

    local candidate_paths=(
        "$HOME/papercut/client/pc-client-linux.sh"
        "$HOME/PaperCut/client/pc-client-linux.sh"
        "/usr/local/papercut/client/pc-client-linux.sh"
        "/opt/papercut/client/pc-client-linux.sh"
        "/opt/PaperCutMF/client/pc-client-linux.sh"
    )
    local found_path=""
    for cp in "${candidate_paths[@]}"; do
        if [ -f "$cp" ] && [ -x "$cp" ]; then
            found_path="$cp"
            break
        fi
    done
    if [ -z "$found_path" ] && command -v pc-client >/dev/null 2>&1; then
        found_path=$(command -v pc-client)
    fi

    echo "${pid}|${found_path}"
}

start_papercut_client() {
    local status
    status=$(get_papercut_status)
    local pid="${status%%|*}"
    local path="${status##*|}"

    if [ -n "$pid" ]; then
        return 0
    fi

    if [ -n "$path" ] && [ -x "$path" ]; then
        nohup "$path" >/dev/null 2>&1 &
        sleep 1
        status=$(get_papercut_status)
        pid="${status%%|*}"
        if [ -n "$pid" ]; then
            return 0
        fi
    fi
    return 1
}

# -------------------------------------------------------------
# ACTION: Show Log File
# -------------------------------------------------------------
show_log_file() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${COLOR_CYAN}Opening log file: $LOG_FILE${COLOR_RESET}"
        if [ -n "${PAGER:-}" ] && command -v "$PAGER" >/dev/null 2>&1; then
            "$PAGER" "$LOG_FILE"
        elif command -v less >/dev/null 2>&1; then
            less "$LOG_FILE"
        else
            cat "$LOG_FILE"
        fi
    else
        echo -e "${COLOR_YELLOW}Log file does not exist yet at: $LOG_FILE${COLOR_RESET}"
    fi
    exit 0
}

# -------------------------------------------------------------
# ACTION: Direct On-Demand Print (Nix / Zero-System-Mutation Mode)
# -------------------------------------------------------------
print_file_on_demand() {
    local file="$1"
    local target_printer="${DEFAULT_PRINTER:-${PRINTERS[0]}}"

    if [ ! -f "$file" ]; then
        echo -e "${COLOR_RED}File not found: '$file'${COLOR_RESET}" >&2
        exit 1
    fi

    show_section_header "DIRECT ON-DEMAND PRINT: $target_printer" "$COLOR_CYAN"
    write_log "  $BOX_ARROW Document : $file" "$COLOR_WHITE"
    write_log "  $BOX_ARROW Copier   : $target_printer" "$COLOR_WHITE"
    write_log "  $BOX_ARROW Target   : $PRINT_SERVER (Fallback IP: $FALLBACK_IP)" "$COLOR_WHITE"

    # Priority 1: Use local CUPS queue if registered and working
    if command -v lpstat >/dev/null 2>&1 && lpstat -p "$target_printer" >/dev/null 2>&1; then
        write_log "  $BOX_ARROW Method   : Local CUPS Queue ($target_printer)... " "$COLOR_WHITE" true
        local print_opts=()
        if [ "$DUPLEX_MODE" = true ]; then
            print_opts+=("-o" "sides=two-sided-long-edge")
        fi
        if lp -d "$target_printer" "${print_opts[@]}" "$file" >/dev/null 2>&1; then
            write_log "SUBMITTED $BOX_CHECK" "$COLOR_GREEN"
            show_notice_box "PRINT JOB DISPATCHED" "$COLOR_GREEN" \
                "Job sent to local CUPS queue '$target_printer'." \
                "PaperCut will hold the job until released at the physical copier."
            exit 0
        else
            write_log "LOCAL CUPS FAILED $BOX_CROSS" "$COLOR_YELLOW"
        fi
    fi

    # Priority 2: Direct SMB spooling (Pure hermetic execution, no local CUPS needed)
    local target_host="$FALLBACK_IP"
    write_log "  $BOX_ARROW Method   : Direct SMB Transmission ($target_host/$target_printer)... " "$COLOR_WHITE" true
    if command -v smbclient >/dev/null 2>&1; then
        if smbclient "//$target_host/$target_printer" -N -c "print $file" >/dev/null 2>&1; then
            write_log "TRANSMITTED $BOX_CHECK" "$COLOR_GREEN"
            show_notice_box "PRINT JOB SUBMITTED DIRECTLY" "$COLOR_GREEN" \
                "Document sent directly over SMB to '$target_host/$target_printer'." \
                "PaperCut will hold the job under user account '${USER:-student}'." \
                "Zero host system changes were made."
            exit 0
        fi
    fi

    write_log "FAILED $BOX_CROSS" "$COLOR_RED"
    echo -e "${COLOR_RED}Unable to transmit print job. Please ensure you are connected to GTG campus Wi-Fi.${COLOR_RESET}" >&2
    exit 1
}

# -------------------------------------------------------------
# ACTION: Restart CUPS Service
# -------------------------------------------------------------
restart_cups_service() {
    show_section_header "SERVICE MAINTENANCE: RESTART PRINT SPOOLER (CUPS)" "$COLOR_YELLOW"
    write_log "  $BOX_ARROW Restarting CUPS service... " "$COLOR_WHITE" true
    if command -v systemctl >/dev/null 2>&1; then
        if sudo systemctl restart cups 2>/dev/null || sudo systemctl restart cups.service 2>/dev/null; then
            write_log "RESTARTED $BOX_CHECK" "$COLOR_GREEN"
        else
            write_log "FAILED $BOX_CROSS" "$COLOR_RED"
        fi
    elif [ -x /etc/init.d/cups ]; then
        if sudo /etc/init.d/cups restart >/dev/null 2>&1; then
            write_log "RESTARTED $BOX_CHECK" "$COLOR_GREEN"
        else
            write_log "FAILED $BOX_CROSS" "$COLOR_RED"
        fi
    else
        write_log "UNKNOWN SERVICE MANAGER $BOX_CROSS" "$COLOR_RED"
    fi
    exit 0
}

# -------------------------------------------------------------
# ACTION: List Installed Network Printers
# -------------------------------------------------------------
list_installed_printers() {
    show_section_header "LOCAL INVENTORY: INSTALLED NETWORK PRINTERS" "$COLOR_CYAN"
    if ! command -v lpstat >/dev/null 2>&1; then
        show_notice_box "CUPS NOT INSTALLED" "$COLOR_RED" "lpstat utility not found. Please install CUPS to manage printers."
        exit 1
    fi

    local installed_raw
    installed_raw=$(lpstat -p 2>/dev/null || true)
    local default_printer
    default_printer=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}' || true)

    if [ -n "$installed_raw" ]; then
        local lines=()
        while IFS= read -r line; do
            if [[ "$line" =~ ^printer\ ([^ ]+) ]]; then
                local pname="${BASH_REMATCH[1]}"
                local def_tag=""
                if [ "$pname" = "$default_printer" ]; then
                    def_tag=" [DEFAULT]"
                fi
                lines+=("$BOX_CHECK  $(printf '%-30s' "$pname")$def_tag")
            fi
        done <<< "$installed_raw"
        lines+=("")
        lines+=("Default Queue: ${default_printer:-None}")
        show_notice_box "MAPPED PRINTER CONNECTIONS" "$COLOR_GREEN" "${lines[@]}"
    else
        show_notice_box "NO PRINTERS FOUND" "$COLOR_YELLOW" "No print queues are currently configured in CUPS."
    fi
    exit 0
}

# -------------------------------------------------------------
# ACTION: Uninstall Printers
# -------------------------------------------------------------
uninstall_printers() {
    show_section_header "UNINSTALLATION: REMOVING PRINTER CONNECTIONS" "$COLOR_YELLOW"
    if ! command -v lpadmin >/dev/null 2>&1; then
        echo -e "${COLOR_RED}lpadmin utility not found. CUPS is required to manage printers.${COLOR_RESET}"
        exit 1
    fi

    local uninstalled_count=0
    local uninstall_results=()

    for p in "${PRINTERS[@]}"; do
        if lpstat -p "$p" >/dev/null 2>&1; then
            if sudo lpadmin -x "$p" 2>/dev/null || lpadmin -x "$p" 2>/dev/null; then
                (( uninstalled_count++ ))
                write_log "  $BOX_ARROW $(printf '%-14s' "$p") : UNINSTALLED $BOX_CHECK" "$COLOR_GREEN"
                uninstall_results+=("$BOX_CHECK  $(printf '%-14s' "$p") : Uninstalled")
            else
                write_log "  $BOX_ARROW $(printf '%-14s' "$p") : FAILED (Permission Denied)" "$COLOR_RED"
                uninstall_results+=("$BOX_CROSS  $(printf '%-14s' "$p") : Failed")
            fi
        else
            write_log "  $BOX_ARROW $(printf '%-14s' "$p") : NOT INSTALLED" "$COLOR_GRAY"
            uninstall_results+=("-  $(printf '%-14s' "$p") : Not Installed")
        fi
    done

    local end_time
    end_time=$(date +%s%N 2>/dev/null || date +%s)
    local elapsed_ms=$(( (end_time - START_TIME) / 1000000 ))
    local elapsed_sec
    elapsed_sec=$(awk "BEGIN {printf \"%.1f\", $elapsed_ms/1000}" 2>/dev/null || echo "0.5")

    local summary_lines=("${uninstall_results[@]}")
    summary_lines+=("")
    summary_lines+=("Total: ${#PRINTERS[@]}  |  Uninstalled: $uninstalled_count  |  Duration: ${elapsed_sec}s")
    summary_lines+=("Log Saved to: $LOG_FILE")

    show_notice_box "UNINSTALLATION OUTCOME" "$COLOR_GREEN" "${summary_lines[@]}"
    exit 0
}

# -------------------------------------------------------------
# ACTION: Interactive Menu Mode (--menu)
# -------------------------------------------------------------
show_interactive_menu() {
    clear
    show_box_title "NETWORK PRINTER MANAGER - LINUX INTERACTIVE MENU" \
        "Server  : $PRINT_SERVER (Fallback IP: $FALLBACK_IP)" \
        "Distro  : $DISTRO_NAME ($DISTRO_ID)" \
        "Network : $(get_active_ssid)"

    echo ""
    echo -e "  ${COLOR_CYAN}=== INSTALLATION OPTIONS ===${COLOR_RESET}"
    echo -e "  [1]  Install All Copiers (L-Kopiator, TB-Kopiator, PB-Kopiator)"
    echo -e "  [2]  Install L-Kopiator only"
    echo -e "  [3]  Install TB-Kopiator only"
    echo -e "  [4]  Install PB-Kopiator only"
    echo -e "  [5]  Install All & Print Test Page"
    echo ""
    echo -e "  ${COLOR_CYAN}=== MANAGEMENT & TOOLS ===${COLOR_RESET}"
    echo -e "  [6]  List Installed Network Printers"
    echo -e "  [7]  Uninstall All Copiers"
    echo -e "  [8]  Restart CUPS Spooler Service"
    echo -e "  [9]  Open Diagnostic Log"
    echo -e "  [10] Check / Launch PaperCut MF Client"
    echo -e "  [0]  Exit"
    echo ""
    read -r -p "  Select an option [0-10]: " choice

    case "$choice" in
        1) "$0" --no-pause; exit 0 ;;
        2) "$0" --printers "L-Kopiator" --default "L-Kopiator" --no-pause; exit 0 ;;
        3) "$0" --printers "TB-Kopiator" --default "TB-Kopiator" --no-pause; exit 0 ;;
        4) "$0" --printers "PB-Kopiator" --default "PB-Kopiator" --no-pause; exit 0 ;;
        5) "$0" --print-test-page --no-pause; exit 0 ;;
        6) "$0" --list-installed; exit 0 ;;
        7) "$0" --uninstall --no-pause; exit 0 ;;
        8) "$0" --restart-cups; exit 0 ;;
        9) "$0" --show-log; exit 0 ;;
        10)
            if start_papercut_client; then
                echo -e "\n${COLOR_GREEN}PaperCut Client started successfully.${COLOR_RESET}"
            else
                echo -e "\n${COLOR_YELLOW}PaperCut Client not found or could not be launched automatically.${COLOR_RESET}"
            fi
            sleep 2
            show_interactive_menu
            ;;
        *) exit 0 ;;
    esac
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: ./install-printers.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -s, --server <host>      Print server hostname (Default: gtcps001.gtc.local)"
            echo "  -i, --fallback-ip <ip>   Direct fallback IP address (Default: 172.16.0.32)"
            echo "  -p, --print <file>       Print a file on-demand directly (no local queue required)"
            echo "  --printers <names>       Space-delimited list of printers to install"
            echo "  --default <name>         Specify default printer"
            echo "  --print-test-page        Send a physical test page to mapped printers"
            echo "  --start-papercut         Automatically launch PaperCut MF Client if detected"
            echo "  --duplex                 Enforce two-sided long-edge duplex policy (default: true)"
            echo "  --no-duplex              Disable default two-sided (duplex) long-edge policy"
            echo "  --uninstall              Uninstall specified GTG copiers"
            echo "  --list-installed         List currently mapped CUPS printers"
            echo "  --restart-cups           Restart local CUPS print spooler"
            echo "  --menu                   Launch interactive numbered menu"
            echo "  --show-log               Open persistent diagnostic log"
            echo "  --force-install          Bypass pre-flight network reachability checks"
            echo "  --no-pause               Suppress interactive pauses"
            exit 0
            ;;
        -s|--server)
            PRINT_SERVER="$2"; shift 2 ;;
        -i|--fallback-ip)
            FALLBACK_IP="$2"; shift 2 ;;
        -p|--print)
            PRINT_FILE="$2"; shift 2 ;;
        --printers)
            IFS=' ' read -r -a PRINTERS <<< "$2"; shift 2 ;;
        --default)
            DEFAULT_PRINTER="$2"; shift 2 ;;
        --print-test-page)
            PRINT_TEST_PAGE=true; shift ;;
        --start-papercut)
            START_PAPERCUT=true; shift ;;
        --duplex)
            DUPLEX_MODE=true; shift ;;
        --no-duplex)
            DUPLEX_MODE=false; shift ;;
        --uninstall)
            UNINSTALL_MODE=true; shift ;;
        --list-installed)
            LIST_INSTALLED_MODE=true; shift ;;
        --restart-cups)
            RESTART_CUPS_MODE=true; shift ;;
        --menu)
            MENU_MODE=true; shift ;;
        --show-log)
            SHOW_LOG_MODE=true; shift ;;
        --force-install)
            FORCE_INSTALL=true; shift ;;
        --no-pause)
            NO_PAUSE=true; shift ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Initialize distro detection
detect_distro
validate_input_params

# Dispatch non-mutating / isolated modes first
if [ "$SHOW_LOG_MODE" = true ]; then show_log_file; fi
if [ "$MENU_MODE" = true ]; then show_interactive_menu; fi
if [ "$LIST_INSTALLED_MODE" = true ]; then list_installed_printers; fi
if [ -n "$PRINT_FILE" ]; then print_file_on_demand "$PRINT_FILE"; fi
if [ "$RESTART_CUPS_MODE" = true ]; then restart_cups_service; fi
if [ "$UNINSTALL_MODE" = true ]; then uninstall_printers; fi

# Guard against accidental imperative mutation on NixOS unless forced
if [ "${IS_NIXOS:-false}" = true ] && [ "$FORCE_INSTALL" = false ]; then
    show_notice_box "NIXOS DETECTED: DECLARATIVE & ON-DEMAND OPTIONS" "$COLOR_CYAN" \
        "NixOS is an immutable, purely functional system. You have 3 architectural paths:" \
        "" \
        "1. ON-DEMAND PRINTING (Hermetic, Zero-System-Mutation - Recommended):" \
        "   Print any document directly without root or altering system options:" \
        "     nix run github:TheHawk09/Printer-Installer -- --print <file.pdf>" \
        "" \
        "2. DECLARATIVE SYSTEM MODULE (Permanent across system rebuilds):" \
        "   Import 'gtg-printers.nix' in /etc/nixos/configuration.nix:" \
        "     imports = [ ./gtg-printers.nix ];" \
        "     services.gtg-printers.enable = true;" \
        "" \
        "3. HOME MANAGER MODULE (User dotfiles without root):" \
        "   Import 'gtg-home.nix' in ~/.config/home-manager/home.nix:" \
        "     imports = [ ./gtg-home.nix ];" \
        "     programs.gtg-printers.enable = true;" \
        "" \
        "(To imperatively configure the active CUPS daemon anyway, re-run with: --force-install)"
    exit 0
fi

# -------------------------------------------------------------
# MAIN INSTALLATION FLOW
# -------------------------------------------------------------
header_lines=(
    "Server    : $PRINT_SERVER (Fallback IP: $FALLBACK_IP)"
    "User      : ${USER:-$(whoami)}"
    "Distro    : $DISTRO_NAME ($DISTRO_ID)"
    "Network   : $(get_active_ssid)"
    "Log File  : $LOG_FILE"
)
if [ "${RUNNING_UNDER_NIX:-0}" = "1" ]; then
    header_lines+=("Runtime   : Nix Store (Hermetic Closure)")
fi

write_log ""
show_box_title "ENTERPRISE NETWORK PRINTER MANAGER (LINUX)" "${header_lines[@]}"

# Step 1: Local CUPS Environment & Backend Diagnostic
show_section_header "STEP 1/4: LOCAL PRINT SPOOLER (CUPS) & BACKENDS" "$COLOR_CYAN"

# Check if lpadmin command exists
write_log "  $BOX_ARROW CUPS Commands (lpadmin)  : " "$COLOR_WHITE" true
if command -v lpadmin >/dev/null 2>&1; then
    write_log "FOUND $BOX_CHECK" "$COLOR_GREEN"
    check_printer_group
else
    write_log "MISSING $BOX_CROSS" "$COLOR_RED"
    echo ""
    echo -e "${COLOR_YELLOW}CUPS printing system is not installed on this system.${COLOR_RESET}"
    echo "To install CUPS for your distribution:"
    case "$DISTRO_ID" in
        arch|manjaro|endeavouros)
            echo "  sudo pacman -S --needed cups samba"
            echo "  sudo systemctl enable --now cups.service"
            ;;
        nixos)
            echo "  Add to your /etc/nixos/configuration.nix:"
            echo "    services.printing.enable = true;"
            echo "  Then run: sudo nixos-rebuild switch"
            ;;
        debian|ubuntu|linuxmint|pop)
            echo "  sudo apt update && sudo apt install -y cups smbclient"
            echo "  sudo systemctl enable --now cups"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            echo "  sudo dnf install -y cups samba-client"
            echo "  sudo systemctl enable --now cups"
            ;;
        opensuse*|suse)
            echo "  sudo zypper install -y cups samba-client"
            echo "  sudo systemctl enable --now cups"
            ;;
        *)
            echo "  Install 'cups' and 'samba-client' via your distribution package manager."
            ;;
    esac
    exit 1
fi

# Check CUPS daemon status
write_log "  $BOX_ARROW CUPS Daemon Status       : " "$COLOR_WHITE" true
cups_running=false
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active cups >/dev/null 2>&1 || systemctl is-active cups.service >/dev/null 2>&1; then
        cups_running=true
    fi
elif [ -S /run/cups/cups.sock ] || [ -S /var/run/cups/cups.sock ]; then
    cups_running=true
fi

if [ "$cups_running" = true ]; then
    write_log "RUNNING $BOX_CHECK" "$COLOR_GREEN"
else
    write_log "STOPPED $BOX_CROSS" "$COLOR_YELLOW"
    write_log "  $BOX_ARROW Auto-starting CUPS... " "$COLOR_WHITE" true
    if command -v systemctl >/dev/null 2>&1 && sudo systemctl start cups >/dev/null 2>&1; then
        write_log "STARTED $BOX_CHECK" "$COLOR_GREEN"
    else
        write_log "FAILED $BOX_CROSS" "$COLOR_RED"
        echo -e "${COLOR_YELLOW}Please start CUPS with: sudo systemctl enable --now cups${COLOR_RESET}"
    fi
fi

# Check CUPS SMB backend (smbspool)
write_log "  $BOX_ARROW CUPS SMB Backend (smb)   : " "$COLOR_WHITE" true
smb_backend_found=false
for b_path in /usr/lib/cups/backend/smb /usr/libexec/cups/backend/smb /var/lib/cups/backend/smb; do
    if [ -x "$b_path" ] || [ -L "$b_path" ]; then
        smb_backend_found=true
        break
    fi
done
if [ "$smb_backend_found" = false ] && command -v lpinfo >/dev/null 2>&1; then
    if lpinfo -v 2>/dev/null | grep -q "network smb"; then
        smb_backend_found=true
    fi
fi

if [ "$smb_backend_found" = true ]; then
    write_log "FOUND $BOX_CHECK" "$COLOR_GREEN"
else
    write_log "MISSING $BOX_CROSS" "$COLOR_YELLOW"
    # Auto-heal: locate smbspool dynamically across PATH, Nix store, or standard FHS
    smbspool_bin=""
    if command -v smbspool >/dev/null 2>&1; then
        smbspool_bin=$(command -v smbspool)
    else
        for b in /usr/bin/smbspool /usr/sbin/smbspool /usr/local/bin/smbspool; do
            if [ -x "$b" ]; then smbspool_bin="$b"; break; fi
        done
    fi

    cups_backend_dir=""
    for d in /var/lib/cups/backend /usr/lib/cups/backend /usr/libexec/cups/backend; do
        if [ -d "$d" ]; then cups_backend_dir="$d"; break; fi
    done

    if [ -n "$smbspool_bin" ] && [ -n "$cups_backend_dir" ]; then
        write_log "  $BOX_ARROW Auto-linking smbspool to CUPS backend... " "$COLOR_WHITE" true
        if sudo ln -sf "$smbspool_bin" "$cups_backend_dir/smb" 2>/dev/null; then
            write_log "LINKED $BOX_CHECK" "$COLOR_GREEN"
            smb_backend_found=true
        else
            write_log "SKIPPED (Requires sudo)" "$COLOR_YELLOW"
        fi
    fi
    if [ "$smb_backend_found" = false ]; then
        write_log "    Note: Samba printing backend (smbclient/samba-client) is recommended for Windows queues." "$COLOR_YELLOW"
    fi
fi

# Check PaperCut MF Client
write_log "  $BOX_ARROW PaperCut MF Client     : " "$COLOR_WHITE" true
pc_status=$(get_papercut_status)
pc_pid="${pc_status%%|*}"
pc_path="${pc_status##*|}"

if [ -n "$pc_pid" ]; then
    write_log "RUNNING (PID $pc_pid) $BOX_CHECK" "$COLOR_GREEN"
elif [ -n "$pc_path" ]; then
    write_log "STOPPED (Found at $pc_path)" "$COLOR_YELLOW"
    if [ "$START_PAPERCUT" = true ]; then
        write_log "  $BOX_ARROW Launching PaperCut... " "$COLOR_WHITE" true
        if start_papercut_client; then
            write_log "STARTED $BOX_CHECK" "$COLOR_GREEN"
        else
            write_log "FAILED $BOX_CROSS" "$COLOR_RED"
        fi
    else
        write_log "    Note: PaperCut client must be running to release jobs at copiers." "$COLOR_GRAY"
    fi
else
    write_log "NOT DETECTED (Run pc-client to release jobs)" "$COLOR_GRAY"
fi

# Step 2: Network & Server Reachability with Interactive Retry
show_section_header "STEP 2/4: NETWORK & SERVER REACHABILITY" "$COLOR_CYAN"

network_loop_active=true
active_server=""

while [ "$network_loop_active" = true ]; do
    write_log "  $BOX_ARROW DNS Host Resolution      : " "$COLOR_WHITE" true
    resolved_ip=""

    # 1. Try standard getent / host / ping
    if command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent ahostsv4 "$PRINT_SERVER" 2>/dev/null | awk '{print $1}' | head -n1 || true)
    elif command -v host >/dev/null 2>&1; then
        resolved_ip=$(host "$PRINT_SERVER" 2>/dev/null | awk '/has address/ {print $4}' | head -n1 || true)
    fi

    if [ -n "$resolved_ip" ] && is_private_ip "$resolved_ip"; then
        write_log "OK ($resolved_ip) $BOX_CHECK" "$COLOR_GREEN"
        active_server="$PRINT_SERVER"
    else
        write_log "PRIMARY DNS UNRESOLVED" "$COLOR_YELLOW"

        # 2. Try querying internal domain controllers
        write_log "  $BOX_ARROW Querying Internal DNS    : " "$COLOR_WHITE" true
        internal_resolved=""
        if command -v dig >/dev/null 2>&1; then
            for dc in "${INTERNAL_DNS_SERVERS[@]}"; do
                res=$(dig +short +time=1 +tries=1 "@$dc" "$PRINT_SERVER" 2>/dev/null || true)
                if [ -n "$res" ] && is_private_ip "$res"; then
                    internal_resolved="$res"
                    write_log "RESOLVED via $dc ($res) $BOX_CHECK" "$COLOR_GREEN"
                    break
                fi
            done
        fi

        if [ -n "$internal_resolved" ]; then
            active_server="$internal_resolved"
        else
            write_log "USING DIRECT IP ($FALLBACK_IP) $BOX_CHECK" "$COLOR_CYAN"
            active_server="$FALLBACK_IP"
        fi
    fi

    # Step 2b: SMB Port 445 Connectivity Probe
    write_log "  $BOX_ARROW Port 445 (SMB) Probe     : " "$COLOR_WHITE" true
    smb_reachable=false

    # Test /dev/tcp with 2 second timeout
    if command -v timeout >/dev/null 2>&1; then
        if timeout 2 bash -c "</dev/tcp/$active_server/445" 2>/dev/null; then
            smb_reachable=true
        fi
    elif command -v nc >/dev/null 2>&1; then
        if nc -z -w 2 "$active_server" 445 2>/dev/null; then
            smb_reachable=true
        fi
    else
        if bash -c "</dev/tcp/$active_server/445" 2>/dev/null; then
            smb_reachable=true
        fi
    fi

    if [ "$smb_reachable" = true ] || [ "$FORCE_INSTALL" = true ]; then
        write_log "OPEN on $active_server $BOX_CHECK" "$COLOR_GREEN"

        # Ping ICMP RTT Latency Telemetry
        write_log "  $BOX_ARROW Ping Latency (ICMP)   : " "$COLOR_WHITE" true
        if command -v ping >/dev/null 2>&1; then
            ping_out=$(ping -c 1 -W 2 "$active_server" 2>/dev/null || true)
            if [ -n "$ping_out" ] && echo "$ping_out" | grep -q "1 received"; then
                rtt=$(echo "$ping_out" | awk -F'/' '/rtt|round-trip/ {print $5}' || true)
                if [ -z "$rtt" ]; then
                    rtt=$(echo "$ping_out" | awk -F'time=' '/time=/ {print $2}' | awk '{print $1}' || true)
                fi
                if [ -n "$rtt" ]; then
                    write_log "${rtt} ms ($active_server) $BOX_CHECK" "$COLOR_GREEN"
                else
                    write_log "REACHABLE ($active_server) $BOX_CHECK" "$COLOR_GREEN"
                fi
            else
                write_log "FILTERED / TIMEOUT" "$COLOR_YELLOW"
            fi
        else
            write_log "SKIPPED (ping not found)" "$COLOR_GRAY"
        fi

        network_loop_active=false
    else
        write_log "TIMEOUT ($active_server:445 unreachable) $BOX_CROSS" "$COLOR_YELLOW"

        # Interactive retry prompt
        if [ -t 0 ] && [ "$NO_PAUSE" = false ]; then
            show_notice_box "NETWORK NOT REACHABLE: RETRY?" "$COLOR_YELLOW" \
                "Cannot reach print server '$active_server' on Port 445 (SMB)." \
                "Current Network: $(get_active_ssid)" \
                "" \
                "Please connect to the GTG school Wi-Fi (GTC Student / Staff) or VPN." \
                "Type 'R' and press Enter to retry, or press Enter / 'Q' to exit."

            read -r -p "  Action: Enter 'R' to Retry, or Enter/Q to Exit: " retry_choice
            if [[ "$retry_choice" =~ ^[rR]$ ]]; then
                echo -e "\n${COLOR_CYAN}Refreshing network interfaces and retrying...${COLOR_RESET}\n"
                if command -v resolvectl >/dev/null 2>&1; then
                    resolvectl flush-caches 2>/dev/null || true
                elif command -v systemd-resolve >/dev/null 2>&1; then
                    systemd-resolve --flush-caches 2>/dev/null || true
                fi
                sleep 2
                continue
            else
                exit 2
            fi
        else
            show_notice_box "CONNECTION BLOCKED: SERVER UNREACHABLE" "$COLOR_RED" \
                "Cannot reach print server '$active_server' on Port 445 (SMB)." \
                "Device must be connected to the GTG internal network." \
                "(To bypass pre-flight check, re-run with: ./install-printers.sh --force-install)"
            exit 2
        fi
    fi
done

# Step 3: Installing & Mapping Printers in CUPS
show_section_header "STEP 3/4: INSTALLING & MAPPING PRINTERS IN CUPS" "$COLOR_CYAN"

total_printers=${#PRINTERS[@]}
install_results=()
success_count=0
fail_count=0

for (( p_idx=0; p_idx<total_printers; p_idx++ )); do
    printer="${PRINTERS[$p_idx]}"
    copier_num=$(( p_idx + 1 ))
    overall_pct=$(( (p_idx * 100) / total_printers ))

    write_log ""
    write_log "  Overall  : $(get_progress_bar_string "$overall_pct") (Copier $copier_num of $total_printers)" "$COLOR_CYAN"
    write_log "  $BOX_ARROW [$copier_num/$total_printers] $printer" "$COLOR_WHITE"

    candidate_uris=("smb://$active_server/$printer")
    if [ -n "$FALLBACK_IP" ] && [ "$active_server" != "$FALLBACK_IP" ]; then
        candidate_uris+=("smb://$FALLBACK_IP/$printer")
    fi

    configured=false
    used_driver=""
    used_uri=""

    for device_uri in "${candidate_uris[@]}"; do
        write_log "    Target : $device_uri" "$COLOR_GRAY"

        # Multi-tier CUPS driver mapping
        # Tier 1: driverless / IPP Everywhere
        # Tier 2: Generic PostScript (drv:///sample.drv/generic.ppd)
        # Tier 3: Raw queue (server renders)
        if sudo lpadmin -p "$printer" -E -v "$device_uri" -m everywhere 2>/dev/null || lpadmin -p "$printer" -E -v "$device_uri" -m everywhere 2>/dev/null; then
            configured=true
            used_driver="IPP Everywhere"
            used_uri="$device_uri"
            break
        elif sudo lpadmin -p "$printer" -E -v "$device_uri" -m "drv:///sample.drv/generic.ppd" 2>/dev/null || lpadmin -p "$printer" -E -v "$device_uri" -m "drv:///sample.drv/generic.ppd" 2>/dev/null; then
            configured=true
            used_driver="Generic PostScript (CUPS)"
            used_uri="$device_uri"
            break
        elif sudo lpadmin -p "$printer" -E -v "$device_uri" -m raw 2>/dev/null || lpadmin -p "$printer" -E -v "$device_uri" -m raw 2>/dev/null; then
            configured=true
            used_driver="Raw Spool Queue"
            used_uri="$device_uri"
            break
        fi
    done

    if [ "$configured" = true ]; then
        (( success_count++ ))
        write_log "    Status : $(get_progress_bar_string 100) CONNECTED $BOX_CHECK" "$COLOR_GREEN"
        write_log "    Driver : $used_driver" "$COLOR_DARKCYAN"

        # Configure Duplex Two-Sided Long-Edge policy
        if [ "$DUPLEX_MODE" = true ] && command -v lpoptions >/dev/null 2>&1; then
            if lpoptions -p "$printer" -o sides=two-sided-long-edge >/dev/null 2>&1; then
                write_log "    Policy : Duplex (Two-Sided Long-Edge) $BOX_CHECK" "$COLOR_DARKCYAN"
            fi
        fi

        # Check default printer setting
        is_default=false
        if [ -n "$DEFAULT_PRINTER" ] && [ "$DEFAULT_PRINTER" = "$printer" ]; then
            write_log "    Default: " "$COLOR_WHITE" true
            if lpoptions -d "$printer" >/dev/null 2>&1 || sudo lpadmin -d "$printer" >/dev/null 2>&1; then
                write_log "SET $BOX_CHECK" "$COLOR_GREEN"
                is_default=true
            else
                write_log "FAILED $BOX_CROSS" "$COLOR_YELLOW"
            fi
        fi

        # Send test page if requested
        test_page_sent=false
        if [ "$PRINT_TEST_PAGE" = true ]; then
            write_log "    TestPage: " "$COLOR_WHITE" true
            if echo "GTG Test Page - $printer - $(date)" | lp -d "$printer" >/dev/null 2>&1; then
                write_log "SENT $BOX_CHECK" "$COLOR_GREEN"
                test_page_sent=true
            else
                write_log "FAILED $BOX_CROSS" "$COLOR_YELLOW"
            fi
        fi

        def_tag=""
        if [ "$is_default" = true ]; then def_tag=" [DEFAULT]"; fi
        t_tag=""
        if [ "$test_page_sent" = true ]; then t_tag=" [TEST PAGE SENT]"; fi
        install_results+=("$BOX_CHECK  $(printf '%-14s' "$printer") : Connected$def_tag$t_tag ($used_driver)")
    else
        (( fail_count++ ))
        write_log "    Status : $(get_progress_bar_string 0) FAILED $BOX_CROSS" "$COLOR_RED"
        write_log "    Details: Could not register queue in CUPS (Check sudo / lpadmin group permissions)" "$COLOR_RED"
        install_results+=("$BOX_CROSS  $(printf '%-14s' "$printer") : Failed")
    fi
done

write_log ""
write_log "  Overall  : $(get_progress_bar_string 100) (All $total_printers copiers processed)" "$COLOR_GREEN"

# Step 4: Final Summary Report
show_section_header "STEP 4/4: FINAL INSTALLATION SUMMARY" "$COLOR_CYAN"

end_time=$(date +%s%N 2>/dev/null || date +%s)
elapsed_ms=$(( (end_time - START_TIME) / 1000000 ))
elapsed_sec=$(awk "BEGIN {printf \"%.1f\", $elapsed_ms/1000}" 2>/dev/null || echo "1.0")

summary_lines=("${install_results[@]}")
summary_lines+=("")
summary_lines+=("Total: $total_printers  |  Succeeded: $success_count  |  Failed: $fail_count  |  Duration: ${elapsed_sec}s")
summary_lines+=("Log Saved to: $LOG_FILE")

if (( fail_count > 0 )); then
    show_notice_box "INSTALLATION OUTCOME" "$COLOR_YELLOW" "${summary_lines[@]}"
else
    show_notice_box "INSTALLATION OUTCOME" "$COLOR_GREEN" "${summary_lines[@]}"
fi

if [ "$NO_PAUSE" = false ] && [ -t 0 ]; then
    echo ""
    read -r -n 1 -s -p "Press any key to close this window..."
    echo ""
fi

if (( fail_count > 0 )); then
    exit 1
else
    exit 0
fi