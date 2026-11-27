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
NO_PAUSE=true
NO_PAUSE_ERROR_VERBOSE=false
PAUSE_ON_ERROR=false
PLAIN_MODE=false
NO_COLOR_MODE=false
if [ -n "${NO_COLOR:-}" ]; then
    NO_COLOR_MODE=true
fi

# SMB Authentication Parameters
SMB_USER="${SMB_USER:-${GTG_USER:-}}"
SMB_PASSWORD="${SMB_PASSWORD:-${GTG_PASSWORD:-}}"
SMB_DOMAIN="${SMB_DOMAIN:-${GTG_DOMAIN:-GTC}}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SMB_CREDENTIALS_FILE="${SMB_CREDENTIALS_FILE:-${GTG_CREDENTIALS:-$XDG_CONFIG_HOME/GTG-Printers/credentials}}"

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LOG_DIR="$XDG_DATA_HOME/GTG-Printers"
LOG_FILE="$LOG_DIR/PrinterInstaller.log"
MAX_LOG_SIZE_BYTES=$((2 * 1024 * 1024)) # 2 MB

RAW_ARG_COUNT=$#

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

init_theme() {
    if [ "$NO_COLOR_MODE" = true ] || [ ! -t 1 ]; then
        COLOR_RESET=""
        COLOR_CYAN=""
        COLOR_DARKCYAN=""
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_RED=""
        COLOR_WHITE=""
        COLOR_GRAY=""
    else
        COLOR_RESET="\033[0m"
        COLOR_CYAN="\033[36m"
        COLOR_DARKCYAN="\033[36;2m"
        COLOR_GREEN="\033[32m"
        COLOR_YELLOW="\033[33m"
        COLOR_RED="\033[31m"
        COLOR_WHITE="\033[37;1m"
        COLOR_GRAY="\033[90m"
    fi

    if [ "$PLAIN_MODE" = true ] || [ ! -t 1 ]; then
        BOX_CHECK="[OK]"
        BOX_CROSS="[FAIL]"
        BOX_ARROW="->"
        BLOCK_FULL="#"
        BLOCK_LIGHT="-"
    else
        BOX_CHECK="✔"
        BOX_CROSS="✘"
        BOX_ARROW="▸"
        BLOCK_FULL="█"
        BLOCK_LIGHT="░"
    fi
}

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
        local clean_msg
        clean_msg=$(printf '%s' "$msg" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null || printf '%s' "$msg")
        echo "[$timestamp] $clean_msg" >> "$LOG_FILE" 2>/dev/null || true
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
    if [ "$PLAIN_MODE" = true ] || [ ! -t 1 ]; then
        write_log "=== $title ===" "$COLOR_CYAN"
        for line in "${lines[@]}"; do
            write_log "  $line" "$COLOR_DARKCYAN"
        done
        return
    fi
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
    if [ "$PLAIN_MODE" = true ] || [ ! -t 1 ]; then
        write_log ""
        write_log "=== $title ===" "$color"
        return
    fi
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
    if [ "$PLAIN_MODE" = true ] || [ ! -t 1 ]; then
        write_log ""
        write_log "[$header]" "$color"
        for line in "${lines[@]}"; do
            write_log "  $line" "$color"
        done
        return
    fi
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
    local should_exit="${1:-true}"
    if [ -f "$LOG_FILE" ]; then
        if [ "$PLAIN_MODE" = true ] || [ ! -t 1 ]; then
            cat "$LOG_FILE"
        else
            echo -e "${COLOR_CYAN}Log file: $LOG_FILE${COLOR_RESET}"
            if [ -n "${PAGER:-}" ] && command -v "$PAGER" >/dev/null 2>&1; then
                "$PAGER" "$LOG_FILE"
            elif command -v less >/dev/null 2>&1; then
                less -R "$LOG_FILE"
            else
                cat "$LOG_FILE"
            fi
        fi
    else
        echo -e "${COLOR_YELLOW}Log file does not exist yet at: $LOG_FILE${COLOR_RESET}"
    fi
    if [ "$should_exit" = true ]; then
        exit 0
    fi
}

# -------------------------------------------------------------
# ACTION: Direct On-Demand Print (Zero Host Mutation)
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
        local lp_err
        if lp_err=$(lp -d "$target_printer" "${print_opts[@]}" "$file" 2>&1); then
            write_log "SUBMITTED $BOX_CHECK" "$COLOR_GREEN"
            show_notice_box "PRINT JOB DISPATCHED" "$COLOR_GREEN" \
                "Job sent to local CUPS queue '$target_printer'." \
                "PaperCut will hold the job until released at the physical copier."
            exit 0
        else
            write_log "LOCAL CUPS FAILED $BOX_CROSS" "$COLOR_YELLOW"
            if [ -n "$lp_err" ]; then
                write_log "    CUPS Error: $lp_err" "$COLOR_GRAY"
            fi
        fi
    fi

    # Priority 2: Direct SMB transmission to print server
    if ! command -v smbclient >/dev/null 2>&1; then
        write_log "FAILED $BOX_CROSS" "$COLOR_RED"
        echo -e "${COLOR_RED}smbclient utility not found. Please install samba-client to use direct SMB printing.${COLOR_RESET}" >&2
        exit 1
    fi

    local smb_targets=("$FALLBACK_IP")
    if [ "$PRINT_SERVER" != "$FALLBACK_IP" ]; then
        smb_targets=("$PRINT_SERVER" "$FALLBACK_IP")
    fi

    # Helper function to execute smbclient cleanly without smb.conf warnings
    try_smb_print() {
        local host="$1"; shift
        smbclient "//$host/$target_printer" -s /dev/null -d 0 -W "$SMB_DOMAIN" "$@" -c "print $file" 2>&1
    }

    # Determine initial credential arguments
    local cred_args=()
    if [ -f "$SMB_CREDENTIALS_FILE" ]; then
        cred_args=("-A" "$SMB_CREDENTIALS_FILE")
    elif [ -n "$SMB_USER" ] && [ -n "$SMB_PASSWORD" ]; then
        cred_args=("-U" "$SMB_USER%$SMB_PASSWORD")
    elif [ -n "$SMB_USER" ]; then
        if [ -t 0 ]; then
            echo -en "  ${COLOR_CYAN}Enter GTG Password for $SMB_USER: ${COLOR_RESET}"
            read -s -r SMB_PASSWORD
            echo ""
            cred_args=("-U" "$SMB_USER%$SMB_PASSWORD")
        fi
    fi

    local transmission_success=false
    local active_user="${SMB_USER:-${USER:-student}}"
    local last_smb_err=""
    local auth_failure=false

    for host in "${smb_targets[@]}"; do
        write_log "  $BOX_ARROW Method   : Direct SMB Transmission ($host/$target_printer)... " "$COLOR_WHITE" true
        local smb_out=""

        # 1. Try with supplied credentials / credentials file if available
        if [ ${#cred_args[@]} -gt 0 ]; then
            if smb_out=$(try_smb_print "$host" "${cred_args[@]}"); then
                transmission_success=true
                write_log "TRANSMITTED $BOX_CHECK" "$COLOR_GREEN"
                break
            fi
            last_smb_err="$smb_out"
            if echo "$smb_out" | grep -qi "ACCESS_DENIED\|LOGON_FAILURE"; then
                auth_failure=true
            fi
        fi

        # 2. Try guest / anonymous
        if smb_out=$(try_smb_print "$host" -U '%'); then
            transmission_success=true
            write_log "TRANSMITTED $BOX_CHECK" "$COLOR_GREEN"
            break
        fi
        last_smb_err="$smb_out"
        if echo "$smb_out" | grep -qi "ACCESS_DENIED\|LOGON_FAILURE"; then
            auth_failure=true
        fi

        # 3. Try with local username (null password)
        if smb_out=$(try_smb_print "$host" -U "${USER:-student}%"); then
            transmission_success=true
            write_log "TRANSMITTED $BOX_CHECK" "$COLOR_GREEN"
            break
        fi
        last_smb_err="$smb_out"
        if echo "$smb_out" | grep -qi "ACCESS_DENIED\|LOGON_FAILURE"; then
            auth_failure=true
        fi

        # 4. Try with -N
        if smb_out=$(try_smb_print "$host" -N); then
            transmission_success=true
            write_log "TRANSMITTED $BOX_CHECK" "$COLOR_GREEN"
            break
        fi
        last_smb_err="$smb_out"
        if echo "$smb_out" | grep -qi "ACCESS_DENIED\|LOGON_FAILURE"; then
            auth_failure=true
        fi

        write_log "FAILED $BOX_CROSS" "$COLOR_YELLOW"
    done

    # If rejected due to authentication in an interactive console, prompt for GTG credentials
    if [ "$transmission_success" = false ] && [ "$auth_failure" = true ] && [ -t 0 ] && [ "$PLAIN_MODE" = false ]; then
        echo ""
        write_log "  [!] Print server ($PRINT_SERVER) requires GTG domain credentials." "$COLOR_YELLOW"
        local p_user=""
        local p_pass=""
        read -r -p "  Enter GTG Username: " p_user
        if [ -n "$p_user" ]; then
            read -s -r -p "  Enter GTG Password: " p_pass
            echo ""
            active_user="$p_user"
            for host in "${smb_targets[@]}"; do
                write_log "  $BOX_ARROW Retrying : Direct SMB Transmission ($host/$target_printer)... " "$COLOR_WHITE" true
                local retry_out
                if retry_out=$(try_smb_print "$host" -U "$p_user%$p_pass"); then
                    transmission_success=true
                    write_log "TRANSMITTED $BOX_CHECK" "$COLOR_GREEN"

                    # Prompt to persist credentials locally
                    local save_ans=""
                    read -r -p "  Save credentials for future printing? [Y/n]: " save_ans
                    if [[ ! "$save_ans" =~ ^[nN]$ ]]; then
                        mkdir -p "$(dirname "$SMB_CREDENTIALS_FILE")" 2>/dev/null || true
                        cat <<EOF > "$SMB_CREDENTIALS_FILE"
username = $p_user
password = $p_pass
domain = $SMB_DOMAIN
EOF
                        chmod 600 "$SMB_CREDENTIALS_FILE" 2>/dev/null || true
                        write_log "  Credentials saved to: $SMB_CREDENTIALS_FILE" "$COLOR_DARKCYAN"
                    fi
                    break
                else
                    last_smb_err="$retry_out"
                    write_log "REJECTED $BOX_CROSS" "$COLOR_RED"
                fi
            done
        fi
    fi

    if [ "$transmission_success" = true ]; then
        show_notice_box "PRINT JOB SUBMITTED DIRECTLY" "$COLOR_GREEN" \
            "Document sent directly over SMB to '$target_printer'." \
            "PaperCut will hold the job under user account '$active_user'." \
            "Swipe your badge or log in at the physical copier to release."
        exit 0
    fi

    write_log "TRANSMISSION FAILED $BOX_CROSS" "$COLOR_RED"
    if [ -n "$last_smb_err" ]; then
        echo -e "${COLOR_YELLOW}Diagnostic: $last_smb_err${COLOR_RESET}" >&2
    fi

    if [ "$auth_failure" = true ]; then
        echo "" >&2
        echo -e "${COLOR_RED}Authentication Error: The print server rejected unauthenticated access (NT_STATUS_ACCESS_DENIED).${COLOR_RESET}" >&2
        echo "GTG network copiers require valid domain credentials so PaperCut can track and release your job." >&2
        echo "" >&2
        echo "Provide credentials via:" >&2
        echo "  ./install-printers.sh print $file --user <gtg_username>" >&2
        echo "  or: export GTG_USER='<username>' GTG_PASSWORD='<password>'" >&2
        echo "  or create: $SMB_CREDENTIALS_FILE (chmod 600)" >&2
    else
        echo -e "${COLOR_RED}Unable to transmit print job. Please verify network connectivity to print server ($PRINT_SERVER / $FALLBACK_IP).${COLOR_RESET}" >&2
    fi
    exit 1
}

# -------------------------------------------------------------
# ACTION: Restart CUPS Service
# -------------------------------------------------------------
restart_cups_service() {
    local should_exit="${1:-true}"
    show_section_header "SERVICE MAINTENANCE: RESTART PRINT SPOOLER (CUPS)" "$COLOR_YELLOW"

    if [ "${IS_NIXOS:-false}" = true ]; then
        write_log "  $BOX_ARROW NixOS: CUPS daemon is managed declaratively." "$COLOR_YELLOW"
        write_log "    Enable via: services.printing.enable = true; in /etc/nixos/configuration.nix" "$COLOR_YELLOW"
        if [ "$should_exit" = true ]; then exit 0; fi
        return 0
    fi

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
    if [ "$should_exit" = true ]; then
        exit 0
    fi
}

# -------------------------------------------------------------
# ACTION: List Installed Network Printers
# -------------------------------------------------------------
list_installed_printers() {
    local should_exit="${1:-true}"
    show_section_header "LOCAL INVENTORY: INSTALLED NETWORK PRINTERS" "$COLOR_CYAN"
    if ! command -v lpstat >/dev/null 2>&1; then
        show_notice_box "CUPS NOT INSTALLED" "$COLOR_RED" "lpstat utility not found. Please install CUPS to manage printers."
        if [ "$should_exit" = true ]; then exit 1; fi
        return 1
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
    if [ "$should_exit" = true ]; then
        exit 0
    fi
}

# -------------------------------------------------------------
# ACTION: Uninstall Printers
# -------------------------------------------------------------
uninstall_printers() {
    local should_exit="${1:-true}"
    show_section_header "UNINSTALLATION: REMOVING PRINTER CONNECTIONS" "$COLOR_YELLOW"
    if ! command -v lpadmin >/dev/null 2>&1; then
        echo -e "${COLOR_RED}lpadmin utility not found. CUPS is required to manage printers.${COLOR_RESET}"
        if [ "$should_exit" = true ]; then exit 1; fi
        return 1
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
    if [ "$should_exit" = true ]; then
        exit 0
    fi
}

# -------------------------------------------------------------
# ACTION: NixOS Declarative Notice
# -------------------------------------------------------------
show_nixos_notice() {
    show_notice_box "NIXOS DETECTED: DECLARATIVE & ON-DEMAND OPTIONS" "$COLOR_CYAN" \
        "NixOS is an immutable, purely functional system. You have 3 architectural paths:" \
        "" \
        "1. DIRECT ON-DEMAND PRINTING (Hermetic, Zero Host Mutation):" \
        "     gtg-printers print <file.pdf>" \
        "   or: nix run github:TheHawk09/Printer-Installer -- print <file.pdf>" \
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
}

# -------------------------------------------------------------
# ACTION: Interactive Menu Mode (--menu)
# -------------------------------------------------------------
show_interactive_menu() {
    while true; do
        if [ "$PLAIN_MODE" = false ] && [ -t 1 ]; then
            clear 2>/dev/null || true
        fi
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
        if [ "${IS_NIXOS:-false}" = true ]; then
            echo -e "  [11] View NixOS Declarative & Flake Guide"
        fi
        echo -e "  [0]  Exit"
        echo ""
        read -r -p "  Select an option [0-11]: " choice

        case "$choice" in
            1)
                PRINTERS=("L-Kopiator" "TB-Kopiator" "PB-Kopiator")
                run_installation_flow false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            2)
                PRINTERS=("L-Kopiator")
                DEFAULT_PRINTER="L-Kopiator"
                run_installation_flow false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            3)
                PRINTERS=("TB-Kopiator")
                DEFAULT_PRINTER="TB-Kopiator"
                run_installation_flow false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            4)
                PRINTERS=("PB-Kopiator")
                DEFAULT_PRINTER="PB-Kopiator"
                run_installation_flow false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            5)
                PRINTERS=("L-Kopiator" "TB-Kopiator" "PB-Kopiator")
                PRINT_TEST_PAGE=true
                run_installation_flow false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            6)
                list_installed_printers false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            7)
                uninstall_printers false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            8)
                restart_cups_service false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            9)
                show_log_file false
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            10)
                if start_papercut_client; then
                    echo -e "\n${COLOR_GREEN}PaperCut Client started successfully.${COLOR_RESET}"
                else
                    echo -e "\n${COLOR_YELLOW}PaperCut Client not found or could not be launched automatically.${COLOR_RESET}"
                fi
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            11)
                show_nixos_notice
                echo ""
                read -r -p "  Press Enter to return to menu... " _
                ;;
            0|q|Q)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid option. Please choose between 0 and 11."
                sleep 1
                ;;
        esac
    done
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: ./install-printers.sh [COMMAND] [OPTIONS]"
            echo ""
            echo "Commands:"
            echo "  install                  Install GTG network copiers (default)"
            echo "  uninstall                Uninstall GTG network copiers"
            echo "  list                     List currently mapped CUPS printers"
            echo "  print <file>             Print a document directly (on-demand)"
            echo "  menu                     Launch interactive console menu"
            echo "  restart-cups             Restart local CUPS print spooler"
            echo "  log                      Display the diagnostic log"
            echo ""
            echo "Options:"
            echo "  -s, --server <host>      Print server hostname (Default: gtcps001.gtc.local)"
            echo "  -i, --fallback-ip <ip>   Direct fallback IP address (Default: 172.16.0.32)"
            echo "  -p, --print <file>       Print a file on-demand directly"
            echo "  -u, --user <username>    GTG domain username for SMB/PaperCut authentication"
            echo "  -w, --password <pass>    GTG domain password"
            echo "  -d, --domain <domain>    SMB NetBIOS domain (Default: GTC)"
            echo "  --credentials <path>     Path to Samba credentials file"
            echo "  --printers <names>       Space-delimited list of printers to install"
            echo "  --default <name>         Specify default printer queue"
            echo "  --print-test-page        Send a physical test page to mapped printers"
            echo "  --start-papercut         Automatically launch PaperCut MF Client if detected"
            echo "  --duplex                 Enforce two-sided long-edge duplex policy (default: true)"
            echo "  --no-duplex              Disable default two-sided (duplex) long-edge policy"
            echo "  --uninstall              Uninstall specified GTG copiers"
            echo "  --list-installed         List currently mapped CUPS printers"
            echo "  --restart-cups           Restart local CUPS print spooler"
            echo "  --menu                   Launch interactive numbered menu"
            echo "  --show-log               Open persistent diagnostic log"
            echo "  --force-install          Bypass pre-flight network checks or force install on NixOS"
            echo "  --pause                  Prompt before closing window on exit"
            echo "  --no-pause               Do not prompt before closing window (default)"
            echo "  --no-pause-error-verbose Dump verbose diagnostics on error without pausing (CI/automation)"
            echo "  --pause-on-error         Do not prompt on success, prompt on exit only if errors occurred"
            echo "  --plain, --no-interactive"
            echo "                           Clean plain-text output (disables TUI boxes and menus)"
            echo "  --no-color               Disable ANSI color codes (also respects NO_COLOR env var)"
            echo "  -h, --help               Display this help text"
            exit 0
            ;;
        -s|--server)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires a hostname argument." >&2; exit 1; fi
            PRINT_SERVER="$2"; shift 2 ;;
        -i|--fallback-ip)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires an IP address argument." >&2; exit 1; fi
            FALLBACK_IP="$2"; shift 2 ;;
        -p|--print)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires a file path argument." >&2; exit 1; fi
            PRINT_FILE="$2"; shift 2 ;;
        -u|--user)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires a username argument." >&2; exit 1; fi
            SMB_USER="$2"; shift 2 ;;
        -w|--password)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires a password argument." >&2; exit 1; fi
            SMB_PASSWORD="$2"; shift 2 ;;
        -d|--domain)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires a domain argument." >&2; exit 1; fi
            SMB_DOMAIN="$2"; shift 2 ;;
        --credentials)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires a credentials file path." >&2; exit 1; fi
            SMB_CREDENTIALS_FILE="$2"; shift 2 ;;
        --printers)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires printer names." >&2; exit 1; fi
            IFS=' ' read -r -a PRINTERS <<< "$2"; shift 2 ;;
        --default)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "Error: $1 requires a printer name." >&2; exit 1; fi
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
        --pause)
            NO_PAUSE=false; shift ;;
        --no-pause)
            NO_PAUSE=true; shift ;;
        --no-pause-error-verbose)
            NO_PAUSE=true
            NO_PAUSE_ERROR_VERBOSE=true
            shift ;;
        --pause-on-error)
            PAUSE_ON_ERROR=true
            shift ;;
        --plain|--no-interactive)
            PLAIN_MODE=true; shift ;;
        --no-color)
            NO_COLOR_MODE=true; shift ;;
        print)
            PRINT_SUBCOMMAND=true
            shift
            if [[ $# -ge 1 && "$1" != -* ]]; then
                PRINT_FILE="$1"
                shift
            fi
            ;;
        list)
            LIST_INSTALLED_MODE=true; shift ;;
        install)
            shift ;;
        uninstall)
            UNINSTALL_MODE=true; shift ;;
        menu)
            MENU_MODE=true; shift ;;
        restart-cups)
            RESTART_CUPS_MODE=true; shift ;;
        log)
            SHOW_LOG_MODE=true; shift ;;
        *)
            if [[ "$1" != -* ]] && [[ -z "$PRINT_FILE" ]]; then
                PRINT_FILE="$1"
                shift
            else
                echo "Unknown option: $1" >&2
                exit 1
            fi
            ;;
    esac
done

if [ "${PRINT_SUBCOMMAND:-false}" = true ] && [ -z "$PRINT_FILE" ]; then
    echo "Error: 'print' subcommand requires a file path." >&2
    echo "Usage: ./install-printers.sh print <file.pdf> [OPTIONS]" >&2
    exit 1
fi

# -------------------------------------------------------------
# MAIN INSTALLATION FLOW
# -------------------------------------------------------------
run_installation_flow() {
    local should_exit="${1:-true}"

    # Guard against accidental imperative mutation on NixOS unless forced
    if [ "${IS_NIXOS:-false}" = true ] && [ "$FORCE_INSTALL" = false ]; then
        show_nixos_notice
        if [ "$should_exit" = true ]; then exit 0; fi
        return 0
    fi

    local header_lines=(
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
        if [ "$should_exit" = true ]; then exit 1; fi
        return 1
    fi

    # Check CUPS daemon status
    write_log "  $BOX_ARROW CUPS Daemon Status       : " "$COLOR_WHITE" true
    local cups_running=false
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
        if [ "${IS_NIXOS:-false}" = true ]; then
            write_log "  $BOX_ARROW NixOS: CUPS service is managed via /etc/nixos/configuration.nix" "$COLOR_YELLOW"
            write_log "    Enable 'services.printing.enable = true;' and run 'sudo nixos-rebuild switch'" "$COLOR_YELLOW"
        else
            write_log "  $BOX_ARROW Auto-starting CUPS... " "$COLOR_WHITE" true
            if command -v systemctl >/dev/null 2>&1 && sudo systemctl start cups >/dev/null 2>&1; then
                write_log "STARTED $BOX_CHECK" "$COLOR_GREEN"
            else
                write_log "FAILED $BOX_CROSS" "$COLOR_RED"
                echo -e "${COLOR_YELLOW}Please start CUPS with: sudo systemctl enable --now cups${COLOR_RESET}"
            fi
        fi
    fi

    # Check CUPS SMB backend (smbspool)
    write_log "  $BOX_ARROW CUPS SMB Backend (smb)   : " "$COLOR_WHITE" true
    local smb_backend_found=false
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
        if [ "${IS_NIXOS:-false}" = true ]; then
            write_log "    NixOS Note: Provide smb backend via 'services.printing.drivers' in gtg-printers.nix" "$COLOR_GRAY"
        else
            # Auto-heal: locate smbspool dynamically across PATH or standard paths
            local smbspool_bin=""
            if command -v smbspool >/dev/null 2>&1; then
                smbspool_bin=$(command -v smbspool)
            else
                for b in /usr/bin/smbspool /usr/sbin/smbspool /usr/local/bin/smbspool; do
                    if [ -x "$b" ]; then smbspool_bin="$b"; break; fi
                done
            fi

            local cups_backend_dir=""
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
    fi

    # Check PaperCut MF Client
    write_log "  $BOX_ARROW PaperCut MF Client     : " "$COLOR_WHITE" true
    local pc_status
    pc_status=$(get_papercut_status)
    local pc_pid="${pc_status%%|*}"
    local pc_path="${pc_status##*|}"

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

    local network_loop_active=true
    local active_server=""

    while [ "$network_loop_active" = true ]; do
        write_log "  $BOX_ARROW DNS Host Resolution      : " "$COLOR_WHITE" true
        local resolved_ip=""

        # 1. Try standard getent / host
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
            local internal_resolved=""
            if command -v dig >/dev/null 2>&1; then
                for dc in "${INTERNAL_DNS_SERVERS[@]}"; do
                    local res
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
        local smb_reachable=false

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
                local ping_out
                ping_out=$(ping -c 1 -W 2 "$active_server" 2>/dev/null || true)
                if [ -n "$ping_out" ] && echo "$ping_out" | grep -q "1 received"; then
                    local rtt
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

                local retry_choice
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
                    if [ "$should_exit" = true ]; then exit 2; fi
                    return 2
                fi
            else
                show_notice_box "CONNECTION BLOCKED: SERVER UNREACHABLE" "$COLOR_RED" \
                    "Cannot reach print server '$active_server' on Port 445 (SMB)." \
                    "Device must be connected to the GTG internal network." \
                    "(To bypass pre-flight check, re-run with: ./install-printers.sh --force-install)"
                if [ "$should_exit" = true ]; then exit 2; fi
                return 2
            fi
        fi
    done

    # Step 3: Installing & Mapping Printers in CUPS
    show_section_header "STEP 3/4: INSTALLING & MAPPING PRINTERS IN CUPS" "$COLOR_CYAN"

    local total_printers=${#PRINTERS[@]}
    local install_results=()
    local success_count=0
    local fail_count=0

    for (( p_idx=0; p_idx<total_printers; p_idx++ )); do
        local printer="${PRINTERS[$p_idx]}"
        local copier_num=$(( p_idx + 1 ))
        local overall_pct=$(( (p_idx * 100) / total_printers ))

        write_log ""
        write_log "  Overall  : $(get_progress_bar_string "$overall_pct") (Copier $copier_num of $total_printers)" "$COLOR_CYAN"
        write_log "  $BOX_ARROW [$copier_num/$total_printers] $printer" "$COLOR_WHITE"

        local candidate_uris=("smb://$active_server/$printer")
        if [ -n "$FALLBACK_IP" ] && [ "$active_server" != "$FALLBACK_IP" ]; then
            candidate_uris+=("smb://$FALLBACK_IP/$printer")
        fi

        local configured=false
        local used_driver=""
        local used_uri=""
        local lp_err=""

        for device_uri in "${candidate_uris[@]}"; do
            write_log "    Target : $device_uri" "$COLOR_GRAY"

            local lp_out
            if lp_out=$(sudo lpadmin -p "$printer" -E -v "$device_uri" -m everywhere 2>&1) || lp_out=$(lpadmin -p "$printer" -E -v "$device_uri" -m everywhere 2>&1); then
                configured=true
                used_driver="IPP Everywhere"
                used_uri="$device_uri"
                break
            fi
            lp_err="$lp_out"

            if lp_out=$(sudo lpadmin -p "$printer" -E -v "$device_uri" -m "drv:///sample.drv/generic.ppd" 2>&1) || lp_out=$(lpadmin -p "$printer" -E -v "$device_uri" -m "drv:///sample.drv/generic.ppd" 2>&1); then
                configured=true
                used_driver="Generic PostScript (CUPS)"
                used_uri="$device_uri"
                break
            fi
            lp_err="$lp_out"

            if lp_out=$(sudo lpadmin -p "$printer" -E -v "$device_uri" -m raw 2>&1) || lp_out=$(lpadmin -p "$printer" -E -v "$device_uri" -m raw 2>&1); then
                configured=true
                used_driver="Raw Spool Queue"
                used_uri="$device_uri"
                break
            fi
            lp_err="$lp_out"
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
            local is_default=false
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
            local test_page_sent=false
            if [ "$PRINT_TEST_PAGE" = true ]; then
                write_log "    TestPage: " "$COLOR_WHITE" true
                if echo "GTG Test Page - $printer - $(date)" | lp -d "$printer" >/dev/null 2>&1; then
                    write_log "SENT $BOX_CHECK" "$COLOR_GREEN"
                    test_page_sent=true
                else
                    write_log "FAILED $BOX_CROSS" "$COLOR_YELLOW"
                fi
            fi

            local def_tag=""
            if [ "$is_default" = true ]; then def_tag=" [DEFAULT]"; fi
            local t_tag=""
            if [ "$test_page_sent" = true ]; then t_tag=" [TEST PAGE SENT]"; fi
            install_results+=("$BOX_CHECK  $(printf '%-14s' "$printer") : Connected$def_tag$t_tag ($used_driver)")
        else
            (( fail_count++ ))
            write_log "    Status : $(get_progress_bar_string 0) FAILED $BOX_CROSS" "$COLOR_RED"
            if [ -n "$lp_err" ]; then
                write_log "    Details: $lp_err" "$COLOR_RED"
            fi
            if [ "${IS_NIXOS:-false}" = true ]; then
                write_log "    NixOS Note: Declarative configuration via gtg-printers.nix is recommended." "$COLOR_YELLOW"
            else
                write_log "    Hint   : Check sudo / lpadmin group permissions or CUPS service status." "$COLOR_GRAY"
            fi
            install_results+=("$BOX_CROSS  $(printf '%-14s' "$printer") : Failed")
        fi
    done

    write_log ""
    write_log "  Overall  : $(get_progress_bar_string 100) (All $total_printers copiers processed)" "$COLOR_GREEN"

    # Step 4: Final Summary Report
    show_section_header "STEP 4/4: FINAL INSTALLATION SUMMARY" "$COLOR_CYAN"

    local end_time
    end_time=$(date +%s%N 2>/dev/null || date +%s)
    local elapsed_ms=$(( (end_time - START_TIME) / 1000000 ))
    local elapsed_sec
    elapsed_sec=$(awk "BEGIN {printf \"%.1f\", $elapsed_ms/1000}" 2>/dev/null || echo "1.0")

    local summary_lines=("${install_results[@]}")
    summary_lines+=("")
    summary_lines+=("Total: $total_printers  |  Succeeded: $success_count  |  Failed: $fail_count  |  Duration: ${elapsed_sec}s")
    summary_lines+=("Log Saved to: $LOG_FILE")

    if (( fail_count > 0 )); then
        show_notice_box "INSTALLATION OUTCOME" "$COLOR_YELLOW" "${summary_lines[@]}"
        if [ "$NO_PAUSE_ERROR_VERBOSE" = true ]; then
            echo "" >&2
            echo "===============================================================================" >&2
            echo "  FAILED PRINTER DEPLOYMENT: VERBOSE ERROR DIAGNOSTICS" >&2
            echo "===============================================================================" >&2
            echo "  * Distro / User    : $DISTRO_NAME ($DISTRO_ID) / ${USER:-$(whoami)}" >&2
            echo "  * Active Network   : $(get_active_ssid)" >&2
            echo "  * Target Server    : $PRINT_SERVER (Fallback: $FALLBACK_IP)" >&2
            echo "  * Spooler Status   : $(command -v systemctl >/dev/null 2>&1 && systemctl is-active cups 2>/dev/null || echo 'unknown')" >&2
            echo "  * SMB Backend      : $(command -v smbspool >/dev/null 2>&1 && echo 'Installed' || echo 'Missing smbspool')" >&2
            if [ -f "$LOG_FILE" ]; then
                echo "" >&2
                echo "  [PERSISTENT LOG: RECENT ENTRIES]" >&2
                tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/    | /' >&2
            fi
            echo "===============================================================================" >&2
            echo "" >&2
        fi
    else
        show_notice_box "INSTALLATION OUTCOME" "$COLOR_GREEN" "${summary_lines[@]}"
    fi

    local should_pause=false
    if [ -t 0 ]; then
        if (( fail_count > 0 )); then
            if [ "$NO_PAUSE" = false ] || [ "$PAUSE_ON_ERROR" = true ]; then
                if [ "$NO_PAUSE_ERROR_VERBOSE" = false ]; then
                    should_pause=true
                fi
            fi
        else
            if [ "$NO_PAUSE" = false ] && [ "$PAUSE_ON_ERROR" = false ]; then
                should_pause=true
            fi
        fi
    fi

    if [ "$should_pause" = true ]; then
        echo ""
        read -r -n 1 -s -p "Press any key to close this window..."
        echo ""
    fi

    if [ "$should_exit" = true ]; then
        if (( fail_count > 0 )); then
            exit 1
        else
            exit 0
        fi
    fi
    return "$fail_count"
}

# -------------------------------------------------------------
# DISPATCH & EXECUTION
# -------------------------------------------------------------
# Initialize distro detection & theme
detect_distro
validate_input_params
init_theme

# If executed with 0 arguments in an interactive terminal, launch menu
if [ "$RAW_ARG_COUNT" -eq 0 ] && [ -t 0 ] && [ -t 1 ] && [ "$PLAIN_MODE" = false ]; then
    show_interactive_menu
    exit 0
fi

# Dispatch non-mutating / isolated modes first
if [ "$SHOW_LOG_MODE" = true ]; then show_log_file true; fi
if [ "$MENU_MODE" = true ]; then show_interactive_menu; fi
if [ "$LIST_INSTALLED_MODE" = true ]; then list_installed_printers true; fi
if [ -n "$PRINT_FILE" ]; then print_file_on_demand "$PRINT_FILE"; fi
if [ "$RESTART_CUPS_MODE" = true ]; then restart_cups_service true; fi
if [ "$UNINSTALL_MODE" = true ]; then uninstall_printers true; fi

# Main installation flow
run_installation_flow true