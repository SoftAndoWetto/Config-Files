#!/usr/bin/env bash
# =============================================================================
#  ctf-launch  —  CTF environment launcher with tmux + VPN automation
#  Providers are discovered dynamically from ~/.vpns/*.ovpn — just drop files
#  in there and they appear automatically.
#
#  -p, --provider <name>    VPN stem (case-insensitive; e.g. "htb-labs", "thm")
#  -t, --target  <IP>       Target IP (enables scan windows)
#  -n, --name    <CTFName>  CTF/box name (used for folder + log naming)
#  -u, --user    <user>     NXC credential username (optional)
#  -P, --pass    <pass>     NXC credential password (optional)
#  -h, --help               Show this help
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[-]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
VPN_DIR="${HOME}/.vpns"
DESKTOP="${HOME}/Desktop"

PROVIDER=""
TARGET_IP=""      # one or more IPs, comma/space/newline separated
CTF_NAME=""
NXC_USER=""
NXC_PASS=""

# ── Discover .ovpn files ──────────────────────────────────────────────────────
# Parallel arrays:
#   OVPN_KEYS         — original-case stems  (e.g. "HTB-Labs")  — display + session
#   OVPN_STEMS_LOWER  — lowercase stems      (e.g. "htb-labs")  — matching
#   OVPN_FILES        — original filenames   (e.g. "HTB-Labs.ovpn")
OVPN_KEYS=()
OVPN_STEMS_LOWER=()
OVPN_FILES=()

load_vpns() {
    [[ -d "$VPN_DIR" ]] || die "VPN directory not found: $VPN_DIR  (run: mkdir ~/.vpns)"
    local f fname stem
    for f in "$VPN_DIR"/*.ovpn; do
        [[ -f "$f" ]] || continue
        fname="$(basename "$f")"
        stem="${fname%.ovpn}"
        OVPN_KEYS+=( "$stem" )
        OVPN_STEMS_LOWER+=( "${stem,,}" )
        OVPN_FILES+=( "$fname" )
    done
    (( ${#OVPN_KEYS[@]} > 0 )) || \
        die "No .ovpn files found in ${VPN_DIR} — add your VPN configs there."
}

# Resolve a user-supplied provider (case-insensitive) to an actual file.
# Sets globals: OVPN_FILE (full path), OVPN_STEM (original case).
# Returns 0 on success, 1 on no match.
find_provider() {
    local needle="${1,,}" i
    for i in "${!OVPN_STEMS_LOWER[@]}"; do
        if [[ "${OVPN_STEMS_LOWER[$i]}" == "$needle" ]]; then
            OVPN_FILE="${VPN_DIR}/${OVPN_FILES[$i]}"
            OVPN_STEM="${OVPN_KEYS[$i]}"
            return 0
        fi
    done
    return 1
}

load_vpns

# ── NXC protocols ─────────────────────────────────────────────────────────────
NXC_PROTOCOLS=(smb ldap ftp winrm mssql ssh wmi rdp)

# ── Shared "wait for host" snippet ────────────────────────────────────────────
# Many CTF targets block ICMP entirely, so a ping-only loop can hang forever
# even when the box is actually reachable (e.g. VPN never connected vs. host
# just doesn't answer pings — you can't tell the difference from ping alone).
# This tries ping first, falls back to a raw TCP connect on common ports
# (80/443/22/445), and gives up with a clear error after a timeout instead of
# spinning silently.
wait_for_host_snippet() {
    local ip="$1" timeout_s="${2:-300}"
    cat <<EOF
echo '[*] Waiting for ${ip} to be reachable (timeout: ${timeout_s}s)...'
_start=\$(date +%s)
_up=0
while true; do
    if ping -c1 -W2 '${ip}' &>/dev/null; then
        _up=1; break
    fi
    # ICMP may be filtered — try a raw TCP connect as a fallback signal
    for _port in 80 443 22 445; do
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${ip}/\${_port}" &>/dev/null; then
            _up=1; break
        fi
    done
    [[ \$_up -eq 1 ]] && break
    if (( \$(date +%s) - _start > ${timeout_s} )); then
        echo '[-] Timed out waiting for ${ip} — check the VPN connection (Window 0) and target IP, then re-run manually.'
        exec bash
    fi
    sleep 3
done
echo '[+] Host up — proceeding'
clear
EOF
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    printf "\n"
    printf "${BOLD}ctf-launch${NC} — spin up a tmux CTF environment with VPN + optional recon\n"
    printf "\n"
    printf "${BOLD}Usage:${NC}\n"
    printf "  ctf-launch [OPTIONS]\n"
    printf "\n"
    printf "${BOLD}Options:${NC}\n"
    printf "  -p, --provider <name>   VPN provider stem (case-insensitive)\n"
    printf "  -t, --target  <ip>      Target IP     (enables scan + nxc windows)\n"
    printf "  -n, --name    <name>    CTF/box name  (folder & log naming)\n"
    printf "  -u, --user    <user>    NXC username  (optional, for credentialled checks)\n"
    printf "  -P, --pass    <pass>    NXC password  (optional, pairs with --user)\n"
    printf "  -h, --help              Show this message\n"
    printf "\n"
    printf "${BOLD}Examples:${NC}\n"
    printf "  # Interactive provider selection, no target\n"
    printf "  ctf-launch\n"
    printf "\n"
    printf "  # Quick launch by provider stem (case-insensitive)\n"
    printf "  ctf-launch -p thm\n"
    printf "\n"
    printf "  # Full launch — VPN + recon + nxc with creds\n"
    printf "  ctf-launch -p htb-labs -t 10.10.11.200 -n FormulaX -u admin -P 'P@ssw0rd'\n"
    printf "\n"
    printf "${BOLD}Discovered VPN providers (%s):${NC}\n" "$VPN_DIR"
    if (( ${#OVPN_KEYS[@]} == 0 )); then
        printf "  ${RED}(none — drop .ovpn files into %s)${NC}\n" "$VPN_DIR"
    else
        local i
        for i in "${!OVPN_KEYS[@]}"; do
            printf "  ${CYAN}%-18s${NC} → %s\n" "${OVPN_STEMS_LOWER[$i]}" "${OVPN_FILES[$i]}"
        done
    fi
    printf "\n"
    exit 0
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--provider) PROVIDER="${2,,}"; shift 2 ;;
        -t|--target)   TARGET_IP="$2";    shift 2 ;;
        -n|--name)     CTF_NAME="$2";     shift 2 ;;
        -u|--user)     NXC_USER="$2";     shift 2 ;;
        -P|--pass)     NXC_PASS="$2";     shift 2 ;;
        -h|--help)     usage ;;
        *) die "Unknown option: $1  (try --help)" ;;
    esac
done

# ── Interactive provider selection ────────────────────────────────────────────
select_provider() {
    echo -e "\n${BOLD}Select VPN provider:${NC}"
    local i n=${#OVPN_KEYS[@]}
    for i in "${!OVPN_KEYS[@]}"; do
        printf "  %d) %-18s  (%s)\n" "$((i+1))" "${OVPN_STEMS_LOWER[$i]}" "${OVPN_FILES[$i]}"
    done
    echo ""
    local choice
    while true; do
        read -rp "Choice [1-${n}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            PROVIDER="${OVPN_STEMS_LOWER[$((choice-1))]}"
            break
        fi
        warn "Please enter a number between 1 and ${n}."
    done
}

[[ -z "$PROVIDER" ]] && select_provider

# ── Validate provider & resolve ovpn file ────────────────────────────────────
OVPN_FILE=""
OVPN_STEM=""
if ! find_provider "$PROVIDER"; then
    die "Unknown provider '$PROVIDER'. Available: ${OVPN_STEMS_LOWER[*]}"
fi
[[ -f "$OVPN_FILE" ]] || die "VPN config not found: $OVPN_FILE"

# ── Derive session name ────────────────────────────────────────────────────────
SESSION="${OVPN_STEM^^}"   # e.g. THM, HTB-LABS, OFFSEC, HACKSMARTER
[[ -n "$CTF_NAME" ]] && SESSION="${SESSION}-${CTF_NAME}"

# -t is always the DC IP (needed distinctly for LDAP etc.) — other lab hosts
# get added by hand into devices.txt below.
TARGET_PRIMARY="$TARGET_IP"

# ── Conflict check ────────────────────────────────────────────────────────────
if tmux has-session -t "$SESSION" 2>/dev/null; then
    warn "Session '$SESSION' already exists."
    read -rp "Attach to existing session? [Y/n]: " ans
    if [[ "${ans,,}" != "n" ]]; then
        tmux attach-session -t "$SESSION"
        exit 0
    fi
    tmux kill-session -t "$SESSION"
fi

# ── Optionally set up CTF folder on Desktop ───────────────────────────────────
CTF_DIR=""
if [[ -n "$CTF_NAME" ]]; then
    CTF_DIR="${DESKTOP}/${CTF_NAME}"
    NMAP_DIR="${CTF_DIR}/Nmap"
    NXC_DIR="${CTF_DIR}/nxc"
    mkdir -p "$NMAP_DIR" "$NXC_DIR"
    for proto in "${NXC_PROTOCOLS[@]}"; do
        mkdir -p "${NXC_DIR}/${proto}"
    done
    success "CTF folder structure created at ${CTF_DIR}"

    # devices.txt lives in the CTF root for nxc to reference. -t is always the
    # DC (needed distinct from other hosts, e.g. for LDAP), so pre-seed it and
    # then force the user into nano to add the rest of the lab hosts by hand
    # before anything else runs.
    DEVICES_FILE="${CTF_DIR}/devices.txt"
    if [[ ! -f "$DEVICES_FILE" ]]; then
        {
            if [[ -n "$TARGET_PRIMARY" ]]; then
                echo "# DC"
                echo "$TARGET_PRIMARY"
            fi
        } > "$DEVICES_FILE"
    fi
    info "Opening devices.txt — add any additional lab hosts, then save & exit (Ctrl+O, Enter, Ctrl+X)."
    nano "$DEVICES_FILE"
fi

# ── Build tmux session ────────────────────────────────────────────────────────
info "Launching tmux session: ${BOLD}${SESSION}${NC}"
info "VPN config: ${OVPN_FILE}"

# Window 0 — VPN
# Prime sudo ONCE here (interactive prompt) and keep it alive in the background
# so every later window that needs sudo (nmap, etc.) doesn't re-prompt.
tmux new-session  -d -s "$SESSION" -n "VPN"
tmux send-keys    -t "${SESSION}:VPN" \
    "echo -e '${GREEN}[+] Authenticating sudo (used for VPN + later scans)${NC}' && sudo -v && ( while true; do sudo -n -v; sleep 60; done & ) && echo -e '${GREEN}[+] Starting VPN: ${OVPN_FILE}${NC}' && sudo openvpn --config '${OVPN_FILE}'" Enter

# Window 1 — Desktop shell
tmux new-window   -t "$SESSION" -n "Shell"
tmux send-keys    -t "${SESSION}:Shell" "cd '${DESKTOP}' && clear" Enter

# ── Optional recon windows (only when -t is provided) ─────────────────────────
if [[ -n "$TARGET_IP" ]]; then

    info "Target(s) in ${DEVICES_FILE:-devices.txt}. Recon windows will start after VPN connects."

    NMAP_OUTDIR="${NMAP_DIR:-${DESKTOP}/Nmap}"
    NMAP_PREFIX="${CTF_NAME:-ctf}"

    # ── Window 2 — Nmap (waits for host to be up) ─────────────────────────────
    tmux new-window -t "$SESSION" -n "Nmap"
    tmux send-keys  -t "${SESSION}:Nmap" "cd '${CTF_DIR:-${DESKTOP}}'" Enter
    tmux send-keys  -t "${SESSION}:Nmap" "
$(wait_for_host_snippet "$TARGET_PRIMARY")
echo '[+] Starting Nmap (primary target: ${TARGET_PRIMARY})'
nmap -sC -sV -p- '${TARGET_PRIMARY}' -oA '${NMAP_OUTDIR}/${NMAP_PREFIX}_Nmap'
echo '[+] Nmap complete. Results in ${NMAP_OUTDIR}/'
" Enter

    # ── Window 3 — Feroxbuster ────────────────────────────────────────────────
    tmux new-window -t "$SESSION" -n "Ferox"
    tmux send-keys  -t "${SESSION}:Ferox" "cd '${CTF_DIR:-${DESKTOP}}'" Enter
    tmux send-keys  -t "${SESSION}:Ferox" "
$(wait_for_host_snippet "$TARGET_PRIMARY")
echo '[+] Starting Feroxbuster (primary target: ${TARGET_PRIMARY})'
feroxbuster -u 'http://${TARGET_PRIMARY}' \
    -w /usr/share/dirbuster/wordlists/directory-list-2.3-medium.txt \
    -x php,html,txt \
    --extract-links \
    -t 50 \
    --scan-dir-listings
" Enter

    # ── Window 4 — NXC sweep across devices.txt (cred / uncred / anon) ────────
    tmux new-window -t "$SESSION" -n "NXC"
    tmux send-keys  -t "${SESSION}:NXC" "cd '${CTF_DIR:-${DESKTOP}}'" Enter

    DEVICES_FILE="${DEVICES_FILE:-${CTF_DIR:-${DESKTOP}}/devices.txt}"
    NXC_CREDS_LINE=""
    if [[ -n "$NXC_USER" && -n "$NXC_PASS" ]]; then
        NXC_CREDS_LINE="nxc \"\$p\" '${DEVICES_FILE}' -u '${NXC_USER}' -p '${NXC_PASS}' 2>&1"
    else
        NXC_CREDS_LINE="echo '(skipped — no -u/-P supplied)'"
    fi

    NXC_SCRIPT=$(cat <<EOF
$(wait_for_host_snippet "$TARGET_PRIMARY")
[[ -f '${DEVICES_FILE}' ]] || { echo 'Error: devices.txt not found at ${DEVICES_FILE}'; exec bash; }

for p in ${NXC_PROTOCOLS[@]}; do
    printf '\033[1;36m=== %s ===\033[0m\n' "\$p"

    echo "[*] Credentialed Authentication"
    ${NXC_CREDS_LINE}

    echo
    echo "[*] Uncredentialed Authentication"
    nxc "\$p" '${DEVICES_FILE}' -u '' -p '' 2>&1

    echo
    echo "[*] Anonymous Authentication"
    nxc "\$p" '${DEVICES_FILE}' -u 'a' -p '' 2>&1

    printf '\n\n'
done
echo '[+] All NXC scans complete.'
EOF
)
    tmux send-keys -t "${SESSION}:NXC" "$NXC_SCRIPT" Enter
fi

# ── Always land on the Shell window ──────────────────────────────────────────
tmux select-window -t "${SESSION}:Shell"

success "Session ${BOLD}${SESSION}${NC} ready — attaching..."
echo ""
echo -e "  ${CYAN}Windows:${NC}"
echo -e "    0: VPN     — OpenVPN running (${OVPN_FILE##*/})"
echo -e "    1: Shell   — ~/Desktop"
if [[ -n "$TARGET_IP" ]]; then
echo -e "    2: Nmap    — full TCP scan (waits for host)"
echo -e "    3: Ferox   — feroxbuster dir-bust (waits for host)"
echo -e "    4: NXC     — netexec all protocols (waits for host)"
fi
echo ""

tmux attach-session -t "$SESSION"