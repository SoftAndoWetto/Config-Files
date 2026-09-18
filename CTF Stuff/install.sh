#!/usr/bin/env bash
# =============================================================================
#  install.sh  —  set up ctf-launch on your machine
#  Run this once from the directory containing the downloaded files.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[*]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Create ~/.vpns
info "Creating ~/.vpns ..."
mkdir -p "$HOME/.vpns"
success "~/.vpns ready"

# 2. Copy ctf-launch.sh to a location on PATH
INSTALL_PATH="$HOME/.local/bin/ctf-launch"
mkdir -p "$HOME/.local/bin"
cp "${SCRIPT_DIR}/ctf-launch.sh" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
success "Installed ctf-launch → ${INSTALL_PATH}"

# 3. Copy tmuxp template
mkdir -p "$HOME/.config/tmuxp"
cp "${SCRIPT_DIR}/ctf-tmuxp.yaml" "$HOME/.config/tmuxp/ctf.yaml"
success "tmuxp template → ~/.config/tmuxp/ctf.yaml"

# 4. Remind user to drop their .ovpn files in place
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  Copy your VPN configs to ~/.vpns/:"
echo "    cp /path/to/TryHackMe.ovpn  ~/.vpns/THM.ovpn"
echo "    cp /path/to/HTB-CTF.ovpn    ~/.vpns/HTB-CTF.ovpn"
echo "    cp /path/to/HTB-acad.ovpn   ~/.vpns/HTB-acad.ovpn"
echo "    cp /path/to/Offsec.ovpn     ~/.vpns/Offsec.ovpn"
echo ""
echo "  Make sure ~/.local/bin is in your PATH:"
echo '    echo '"'"'export PATH="$HOME/.local/bin:$PATH"'"'"' >> ~/.bashrc && source ~/.bashrc'
echo ""
echo "  Then launch with:"
echo "    ctf-launch                                # interactive provider picker"
echo "    ctf-launch -p htb                         # quick HTB shell + VPN"
echo "    ctf-launch -p htb -t 10.10.11.200 -n FormulaX          # + recon"
echo "    ctf-launch -p thm -t 10.10.x.x -n RoomName -u admin -P pass  # + nxc creds"
echo ""
success "Install complete!"
