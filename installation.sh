#!/usr/bin/env bash
# Run as a normal (sudo-capable) user:
#   curl -sL https://raw.githubusercontent.com/SoftAndoWetto/Config-Files/refs/heads/main/Base/setup.sh | bash
set -uo pipefail

RAW="https://raw.githubusercontent.com/SoftAndoWetto/Config-Files/refs/heads/main/Base"
export DEBIAN_FRONTEND=noninteractive
FAILED=()

if [ "$(id -u)" -eq 0 ]; then
    echo "[!] Run as a normal user with sudo, not root." >&2
    exit 1
fi

sudo -v || { echo "[!] sudo required" >&2; exit 1; }

try() { "$@" || FAILED+=("$*"); }
apt_i() { try sudo apt-get install -y "$@"; }
BLOCK_BEGIN="# >>> SoftAndoWetto shellrc_stuff >>>"
BLOCK_END="# <<< SoftAndoWetto shellrc_stuff <<<"

# sappend_once <file> <marker> <text>  (root-owned file)
# Skips if <marker> already appears anywhere in the file.
sappend_once() {
    if sudo grep -qF -- "$2" "$1" 2>/dev/null; then
        echo "[=] $1: '$2' already present, skipping"
    else
        printf '%s\n' "$3" | sudo tee -a "$1" > /dev/null
    fi
}

# append_block_once <file> <blockfile>
# Skips if our markers exist OR every non-blank line of the block is already
# in the file (covers earlier manual / old-script installs without markers).
append_block_once() {
    local f="$1" blk="$2"
    if grep -qF -- "$BLOCK_BEGIN" "$f" 2>/dev/null; then
        echo "[=] $f: shellrc_stuff block already present (marker), skipping"
    elif [ -z "$(grep -v '^[[:space:]]*$' "$blk" | grep -vxFf "$f" 2>/dev/null)" ]; then
        echo "[=] $f: shellrc_stuff content already present, skipping"
    else
        { echo "$BLOCK_BEGIN"; cat "$blk"; echo "$BLOCK_END"; } >> "$f"
        echo "[+] $f: shellrc_stuff appended"
    fi
}

#######################################################################
######################## SYSTEM PREPARATION ###########################
#######################################################################
echo "[*] System preparation"
[ -f /etc/apt/sources.list ] && try sudo sed -i '5s/^# //' /etc/apt/sources.list
try sudo apt-get update
try sudo apt-get upgrade -y
try sudo apt-get dist-upgrade -y

apt_i curl wget git unzip ca-certificates
apt_i docker.io docker-compose golang open-iscsi rustc seclists rlwrap tmux tmuxp fzf

try bash -c 'curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh'
try sudo usermod -aG docker "$USER"

touch ~/.bashrc ~/.zshrc
TMP_RC="$(mktemp)"
if curl -sSfL "$RAW/shellrc_stuff" -o "$TMP_RC" && [ -s "$TMP_RC" ]; then
    for rc in ~/.bashrc ~/.zshrc; do
        append_block_once "$rc" "$TMP_RC"
    done
else
    FAILED+=("download shellrc_stuff")
fi
rm -f "$TMP_RC"

#######################################################################
##################### MODERN CLI REPLACEMENTS #########################
#######################################################################
echo "[*] Modern CLI replacements"
apt_i bat ripgrep fd-find eza

# Debian names: batcat / fdfind
mkdir -p ~/.local/bin
command -v batcat >/dev/null && [ ! -e ~/.local/bin/bat ] && ln -s "$(command -v batcat)" ~/.local/bin/bat
command -v fdfind >/dev/null && [ ! -e ~/.local/bin/fd ] && ln -s "$(command -v fdfind)" ~/.local/bin/fd

mkdir -p ~/.config/eza
try curl -sSfL https://raw.githubusercontent.com/eza-community/eza-themes/refs/heads/main/themes/catppuccin-frappe.yml -o ~/.config/eza/theme.yaml
printf '%s\n' '#command' 'j forw-line' 'k back-line' 'h left-scroll' 'l right-scroll' > ~/.lesskey

#######################################################################
######################## STARSHIP CONFIG ##############################
#######################################################################
echo "[*] Starship"
try bash -c 'curl -sS https://starship.rs/install.sh | sudo sh -s -- -y -b /usr/bin'

mkdir -p ~/.local/share/fonts
(
    cd ~/.local/share/fonts \
    && wget -q https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip -O FiraCode.zip \
    && unzip -oq FiraCode.zip -d FiraCode \
    && rm -f FiraCode.zip \
    && fc-cache -f
) || FAILED+=("FiraCode nerd font")

sudo mkdir -p /etc/starship
try sudo wget -q -O /etc/starship/starship.toml "$RAW/starship.toml"

# Root shells
sudo touch /root/.bashrc /root/.zshrc
sappend_once /root/.bashrc 'STARSHIP_CONFIG' 'export STARSHIP_CONFIG=/etc/starship/starship.toml'
sappend_once /root/.bashrc 'starship init bash' 'eval "$(starship init bash)"'
sappend_once /root/.bashrc 'SHELL_DEPTH' 'export SHELL_DEPTH=$(( ${SHELL_DEPTH:-0} + 1 ))'
sappend_once /root/.zshrc 'STARSHIP_CONFIG' 'export STARSHIP_CONFIG=/etc/starship/starship.toml'
sappend_once /root/.zshrc 'starship init zsh' 'eval "$(starship init zsh)"'
sappend_once /root/.zshrc 'SHELL_DEPTH' 'export SHELL_DEPTH=$(( ${SHELL_DEPTH:-0} + 1 ))'

#######################################################################
########################### TMUX CONFIG ###############################
#######################################################################
echo "[*] tmux / tmuxp"
[ -d ~/.tmux/plugins/tpm ] || try git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
try wget -q -O ~/.tmux.conf "$RAW/tmux.conf"
mkdir -p ~/.tmuxp
try wget -q -O ~/.tmuxp/long_scans.yaml "$RAW/long_scans.yaml"
[ -x ~/.tmux/plugins/tpm/bin/install_plugins ] && { ~/.tmux/plugins/tpm/bin/install_plugins >/dev/null 2>&1 || true; }

#######################################################################
################## DISPLAY / LOCKSCREEN SETTINGS ######################
#######################################################################
# (add your commands here)

#######################################################################
################################ DONE #################################
#######################################################################
echo
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "[!] Failed steps:"
    printf '    - %s\n' "${FAILED[@]}"
else
    echo "[+] All steps completed."
fi
echo "[*] Log out/in for docker group; open a new shell for prompt/aliases."
