#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  ZenithArch Shell · Bootstrap  (hf202.1, self-healing)
# ═══════════════════════════════════════════════════════════════
#  Installs Hyprland + Quickshell + every Zen Shell system dep on
#  an Arch-based system (Arch, CachyOS, EndeavourOS, Manjaro).
#
#  You normally never run this by hand. install.sh detects missing
#  deps and calls it automatically. Running it directly still works:
#
#      ./bootstrap.sh            auto-yes, smart: installs only what is
#                                missing (--needed), upgrades only when
#                                pacman actually has pending updates
#      ./bootstrap.sh --ask      interactive (Y/n prompts)
#      ./bootstrap.sh --doctor   diagnose "login bounces back to the
#                                greeter": session entries, GPU / 3D
#                                accel, last Hyprland log, crash reports
#
#  Safe next to KDE / GNOME / COSMIC:
#    - does NOT touch the display manager (SDDM / GDM / cosmic-greeter)
#    - does NOT change the default session or autologin
#    - leaves the current DE installed and selectable
#
#  hf202.1 fixes (why Hyprland was "missing" at the login screen):
#
#    1. BROKEN AUR HELPER NO LONGER BLOCKS HYPRLAND.
#       The old script sent EVERY package through paru. A paru built
#       against an older pacman dies instantly with
#           libalpm.so.15: cannot open shared object file
#       (pacman 7.1 ships libalpm.so.16), so nothing installed, not
#       even Hyprland. Official-repo packages now go straight through
#       pacman. Hyprland, Quickshell (extra/quickshell), jq and Qt6 are
#       all official, so the core lands even with no AUR helper.
#
#    2. BROKEN HELPERS ARE REPAIRED. A paru/yay that exists but cannot
#       run is detected (not just "command -v") and rebuilt from the
#       AUR against the current libalpm. Last resort: yay from source.
#
#    3. NO MORE FAKE "COMPLETE". The old script printed BOOTSTRAP
#       COMPLETE and exit 0 even when every package failed. The core
#       (Hyprland, hyprctl, Quickshell, jq) is now verified and the
#       script exits 1 with a clear reason if any is missing.
#
#    4. NO MORE GHOST SESSION ENTRY. The old script wrote
#       /usr/share/wayland-sessions/hyprland.desktop even when Hyprland
#       never installed. The login screen then offered "Hyprland" that
#       could not start, AND the next `pacman -S hyprland` failed with
#       "exists in filesystem" because the hyprland package owns that
#       exact path. The stale, unowned file is now moved aside before
#       install, and a session entry is only written if the package
#       did not ship one.
#
#    5. ONE BAD PACKAGE NO LONGER KILLS THE BATCH. Names are resolved
#       first (installed / repo / AUR / gone, with alternates such as
#       awww|swww). Each tier installs as a batch; if a batch fails it
#       retries one package at a time so one conflict or rename only
#       skips that one package.
#
#    6. SYSTEM SYNC FIRST. `pacman -Syu` runs before installing (Arch
#       does not support partial upgrades) and retries once with a
#       keyring refresh. Opt out: ZEN_NO_SYSUPGRADE=1.
#
#    7. SMART BY DEFAULT (hf202.2). Auto-yes, no prompts. Package DB is
#       refreshed, then `pacman -Qu` decides: no pending updates means
#       no upgrade pass at all; packages already present are skipped
#       (--needed); a healthy AUR helper is left alone. A second run on
#       a finished system does nothing but verify.
#
#  Env:
#    ZEN_BOOTSTRAP_ASK=1      Y/n prompts (same as --ask)
#    ZEN_BOOTSTRAP_AUTO=1     force auto-yes (install.sh sets this)
#    ZEN_NO_SYSUPGRADE=1      skip the DB refresh + upgrade (not recommended)
#    ZEN_QUICKSHELL_PKG=...   force a quickshell package, for example
#                             quickshell-git (default: repo quickshell)
# ═══════════════════════════════════════════════════════════════
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# hf202.2: auto-yes is the default. --ask (or ZEN_BOOTSTRAP_ASK=1)
# brings the Y/n prompts back. ZEN_BOOTSTRAP_AUTO=1 always wins.
AUTO=1
[ "${ZEN_BOOTSTRAP_ASK:-0}" = "1" ] && AUTO=0
[ "${ZEN_BOOTSTRAP_AUTO:-0}" = "1" ] && AUTO=1
MODE="install"

for arg in "$@"; do
    case "$arg" in
        --yes|-y)   AUTO=1 ;;
        --ask|-i)   AUTO=0 ;;
        --doctor)   MODE="doctor" ;;
        --help|-h)
            sed -n '2,75p' "${BASH_SOURCE[0]}" | sed 's/^#//'
            exit 0
            ;;
    esac
done

# ── Colors (plain if no tty) ──
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[0;32m'
    C_CYN=$'\033[0;36m'; C_DIM=$'\033[2m';    C_END=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""; C_DIM=""; C_END=""
fi

ok()   { echo "    ${C_GRN}✓${C_END} $*"; }
warn() { echo "    ${C_YEL}⚠${C_END} $*"; }
bad()  { echo "    ${C_RED}✗${C_END} $*"; }
note() { echo "    ${C_DIM}$*${C_END}"; }
step() { echo ""; echo "${C_CYN}[$1/8]${C_END} $2"; }

# Default-yes prompt. Returns 0 for yes. Always yes in AUTO mode.
ask() {
    [ "$AUTO" = "1" ] && return 0
    local a=""
    if [ -r /dev/tty ]; then
        read -r -p "$1" a </dev/tty || a=""
    fi
    case "${a,,}" in n|no) return 1 ;; *) return 0 ;; esac
}

have_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && return 0; done; return 1; }

# ═══════════════════════════════════════════════════════════════
# --doctor : why does login bounce back to the greeter?
# ═══════════════════════════════════════════════════════════════
# Read-only. Run it from a TTY (Ctrl+Alt+F3) right after a failed
# login attempt, or from any other desktop session.
zen_doctor() {
    local d f bin exec_line name virt latest
    echo ""
    echo "    ZenithArch Shell · login doctor"
    echo "    ─────────────────────────────────────────────────────"

    echo ""
    echo "  [1] Hyprland install"
    if have_cmd Hyprland hyprland; then
        ok "binary: $(command -v Hyprland 2>/dev/null || command -v hyprland)"
        note "$(Hyprland --version 2>/dev/null | head -1 || hyprland --version 2>/dev/null | head -1)"
    else
        bad "Hyprland binary NOT found. Run ./bootstrap.sh (or ./install.sh)."
    fi
    have_cmd quickshell qs && ok "quickshell: $(command -v quickshell 2>/dev/null || command -v qs)" || bad "quickshell missing"
    if pgrep -x Hyprland >/dev/null 2>&1; then
        ok "Hyprland is running right now (pid $(pgrep -x Hyprland | head -1))"
    fi

    echo ""
    echo "  [2] Login session entries (/usr/share/wayland-sessions)"
    shopt -s nullglob
    for f in /usr/share/wayland-sessions/*.desktop; do
        exec_line=$(grep -m1 '^Exec=' "$f" | cut -d= -f2-)
        bin="${exec_line%% *}"
        name=$(grep -m1 '^Name=' "$f" | cut -d= -f2-)
        case "$name$f" in *[Hh]yprland*) ;; *) continue ;; esac
        if command -v "$bin" >/dev/null 2>&1; then
            ok "\"$name\"  Exec=$exec_line"
        else
            bad "\"$name\"  Exec=$exec_line   ('$bin' NOT installed: picking this one bounces to the greeter)"
        fi
        pacman -Qo "$f" >/dev/null 2>&1 || note "    ($(basename "$f") is not owned by any package)"
    done
    shopt -u nullglob

    echo ""
    echo "  [3] GPU / 3D acceleration"
    virt="$(systemd-detect-virt 2>/dev/null || true)"; [ "$virt" = "none" ] && virt=""
    [ -n "$virt" ] && note "virtual machine: $virt" || note "bare metal"
    if compgen -G "/dev/dri/card*" >/dev/null 2>&1; then
        ok "DRM nodes: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
    else
        bad "no /dev/dri/card*: no KMS device at all, Hyprland cannot start"
    fi
    if ! compgen -G "/dev/dri/renderD*" >/dev/null 2>&1; then
        bad "no /dev/dri/renderD*: no render node = no 3D. In VMware enable"
        note "    VM Settings > Display > Accelerate 3D graphics (VM powered off)."
    fi
    if command -v lsmod >/dev/null 2>&1; then
        lsmod 2>/dev/null | grep -qE '^(vmwgfx|virtio_gpu|vboxvideo|amdgpu|i915|xe|nouveau|nvidia)' \
            && note "gpu driver: $(lsmod | grep -oE '^(vmwgfx|virtio_gpu|vboxvideo|amdgpu|i915|xe|nouveau|nvidia)' | tr '\n' ' ')" \
            || warn "no known GPU kernel driver loaded"
    fi
    if command -v eglinfo >/dev/null 2>&1; then
        note "EGL: $(eglinfo -B 2>/dev/null | grep -m1 -iE 'renderer|OpenGL ES profile renderer' | sed 's/^ *//')"
    elif command -v glxinfo >/dev/null 2>&1; then
        note "GL: $(glxinfo -B 2>/dev/null | grep -m1 -i 'renderer' | sed 's/^ *//')"
    else
        note "(install mesa-utils for a renderer check: sudo pacman -S mesa-utils)"
    fi
    for f in "$HOME/.config/hypr/hyprland.conf" "$HOME/.config/hypr/modules/hardware.conf"; do
        [ -f "$f" ] && grep -q 'no_hardware_cursors' "$f" && note "software cursor set in ~/${f#"$HOME"/}"
    done

    echo ""
    echo "  [4] Hyprland config check"
    if [ -f "$HOME/.config/hypr/hyprland.conf" ]; then
        ok "hyprland.conf found in ~/.config/hypr"
        if have_cmd Hyprland && Hyprland --help 2>&1 | grep -q -- '--verify-config'; then
            if Hyprland --verify-config >/tmp/zen-verify.$$ 2>&1; then
                ok "Hyprland --verify-config: OK"
            else
                warn "Hyprland --verify-config reported problems:"
                grep -iE 'err|invalid|fail' /tmp/zen-verify.$$ | head -15 | sed 's/^/        /'
            fi
            rm -f /tmp/zen-verify.$$
        fi
    else
        bad "no ~/.config/hypr/hyprland.conf (Hyprland writes a default one, this alone does not bounce)"
    fi

    echo ""
    echo "  [5] Last Hyprland session log"
    d="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr"
    latest=""
    if [ -d "$d" ]; then
        latest=$(ls -t "$d" 2>/dev/null | head -1)
    fi
    if [ -n "$latest" ] && [ -f "$d/$latest/hyprland.log" ]; then
        note "$d/$latest/hyprland.log (last 40 lines, errors first):"
        grep -iE 'ERR|CRIT|fail|cannot|could not|no such|backend' "$d/$latest/hyprland.log" | tail -20 | sed 's/^/        /'
        echo "        ..."
        tail -n 12 "$d/$latest/hyprland.log" | sed 's/^/        /'
    else
        warn "no session log under $d. Hyprland never got far enough to log,"
        note "or the greeter started it with another runtime dir. See [6] and [7]."
    fi
    shopt -s nullglob
    local crashes=("${XDG_CACHE_HOME:-$HOME/.cache}"/hyprland/hyprlandCrashReport*.txt)
    shopt -u nullglob
    if [ ${#crashes[@]} -gt 0 ]; then
        warn "crash reports found: ${#crashes[@]}"
        latest=$(ls -t "${crashes[@]}" | head -1)
        note "newest: $latest"
        grep -m3 -iE 'signal|Version|Tag' "$latest" | sed 's/^/        /'
    else
        ok "no Hyprland crash reports in ~/.cache/hyprland"
    fi

    echo ""
    echo "  [6] Journal (this boot, greeter / session / gpu lines)"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -b --no-pager -o short 2>/dev/null \
            | grep -iE 'hyprland|greetd|cosmic-greeter|sddm|gdm|wayland-session|vmwgfx|virtio_gpu|drm.*(error|fail)|segfault' \
            | tail -25 | sed 's/^/        /'
    fi

    echo ""
    echo "  [7] Manual test"
    echo "      Ctrl+Alt+F3, log in, then run:   Hyprland"
    echo "      Errors print straight to the TTY. Ctrl+Alt+F1 (or F2) returns to the greeter."
    echo ""
    echo "      Copy everything above into the chat if it is not obvious."
    echo ""
}
if [ "$MODE" = "doctor" ]; then
    zen_doctor
    exit 0
fi

# Version label read from the shell itself, same source as install.sh
ZEN_VER=""
for _q in "$SCRIPT_DIR/zen-shell/ZenVersion.qml" "$SCRIPT_DIR/zen-shell-v5/ZenVersion.qml"; do
    if [ -f "$_q" ]; then
        _semver=$(sed -nE 's/.*property string semver:[[:space:]]*"([0-9.]+)".*/\1/p' "$_q" | head -1)
        _patch=$(sed -nE 's/.*property int[[:space:]]+patchNum:[[:space:]]*([0-9]+).*/\1/p' "$_q" | head -1)
        _hf=$(sed -nE 's/.*property string hotfix:[[:space:]]*"([^"]*)".*/\1/p' "$_q" | head -1)
        [ -n "$_semver" ] && ZEN_VER="v${_semver}${_patch}${_hf:+-$_hf}"
        break
    fi
done

echo ""
echo "    ZenithArch Shell ${ZEN_VER:-v8} · Bootstrap (self-healing)"
echo "    ─────────────────────────────────────────────────────"
echo "    Installs Hyprland + Quickshell + Zen Shell system deps."
echo "    Official packages go through pacman directly, the AUR"
echo "    helper is only used for AUR-only extras."
echo "    Your current DE, display manager and default session"
echo "    are left alone."
echo "    ─────────────────────────────────────────────────────"

# ═══════════════════════════════════════════════════════════════
# [1/8] System checks
# ═══════════════════════════════════════════════════════════════
step 1 "System checks..."

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    bad "Do not run this as root / with sudo."
    note "Run it as your normal user. It asks for sudo itself, and"
    note "makepkg (AUR builds) refuses to run as root."
    exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
    bad "pacman not found"
    note "Bootstrap supports Arch-based distros only (Arch, CachyOS,"
    note "EndeavourOS, Manjaro). Elsewhere, install Hyprland +"
    note "Quickshell + jq with your package manager, then run install.sh."
    exit 1
fi

if ! pacman --version >/dev/null 2>&1; then
    bad "pacman itself does not run:"
    pacman --version 2>&1 | head -2 | sed 's/^/      /'
    note "Fix pacman first (see the pacman-static page on the Arch wiki)."
    exit 1
fi

DISTRO_NAME="Arch Linux"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    DISTRO_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-Arch Linux}")"
fi
_pacver=$(pacman -Q pacman 2>/dev/null | awk '{print $2}')
ok "$DISTRO_NAME${_pacver:+ (pacman $_pacver)}"

LIBALPM_NOW=$(ls /usr/lib/libalpm.so.[0-9]* 2>/dev/null | sed -E 's@.*/libalpm\.so\.([0-9]+).*@\1@' | sort -n | tail -1)
[ -n "$LIBALPM_NOW" ] && note "libalpm.so.$LIBALPM_NOW is the current pacman library"

CURRENT_DE="${XDG_CURRENT_DESKTOP:-unknown}"
DM_RUNNING=""
for dm in sddm gdm lightdm lxdm ly greetd cosmic-greeter; do
    if systemctl is-active --quiet "$dm" 2>/dev/null; then DM_RUNNING="$dm"; break; fi
done
note "Current desktop: $CURRENT_DE   Display manager: ${DM_RUNNING:-(none detected)}"

VIRT="$(systemd-detect-virt 2>/dev/null || true)"
[ "$VIRT" = "none" ] && VIRT=""
[ -n "$VIRT" ] && note "Virtual machine detected: $VIRT"

case "${CURRENT_DE,,}" in
    *plasma*|*kde*|*gnome*|*cosmic*|*sway*)
        note "You are in $CURRENT_DE. That is fine: after this, log out and"
        note "pick Hyprland at the login screen. $CURRENT_DE stays available."
        ;;
esac

# Ask for sudo once and keep it alive for the whole run
echo ""
note "sudo is needed for pacman. Enter your password once:"
if ! sudo -v; then
    bad "sudo failed. Cannot install packages."
    exit 1
fi
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 45; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# Pacman lock: wait for a running package manager, clear a stale lock
PAC_LOCK="/var/lib/pacman/db.lck"
if [ -e "$PAC_LOCK" ]; then
    if pgrep -x 'pacman|paru|yay|pamac|pamac-daemon|packagekitd|cosmic-store' >/dev/null 2>&1; then
        warn "Another package manager holds the pacman lock. Waiting up to 90s..."
        for _i in $(seq 1 90); do [ -e "$PAC_LOCK" ] || break; sleep 1; done
    fi
    if [ -e "$PAC_LOCK" ]; then
        if pgrep -x 'pacman|paru|yay|pamac' >/dev/null 2>&1; then
            bad "pacman is still locked by a running process. Close it and re-run."
            exit 1
        fi
        warn "Removing stale pacman lock ($PAC_LOCK)"
        sudo rm -f "$PAC_LOCK"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# [2/8] Sync + full upgrade
# ═══════════════════════════════════════════════════════════════
step 2 "Refresh package DB + upgrade only if needed..."

_have_sync_db() { compgen -G "/var/lib/pacman/sync/*.db" >/dev/null 2>&1; }

_do_upgrade() {   # returns 0 if the system ends up current
    local n
    n=$(pacman -Qu 2>/dev/null | grep -vc '\[ignored\]')
    if [ "${n:-0}" -eq 0 ]; then
        ok "No pending updates, skipping upgrade"
        return 0
    fi
    echo "    $n package update(s) pending, upgrading..."
    sudo pacman -Su --noconfirm && ok "System upgraded ($n package(s))"
}

if [ "${ZEN_NO_SYSUPGRADE:-0}" = "1" ] && _have_sync_db; then
    warn "ZEN_NO_SYSUPGRADE=1, using the existing package DB, no upgrade"
else
    if sudo pacman -Sy --noconfirm >/dev/null 2>&1; then
        ok "Package databases refreshed"
    else
        warn "DB refresh failed, retrying visibly..."
        sudo pacman -Sy --noconfirm || warn "Could not refresh package DB (mirror down?)"
    fi
    if ! _do_upgrade; then
        warn "Upgrade failed. Refreshing keyrings and retrying once..."
        _keyrings="archlinux-keyring"
        for _k in cachyos-keyring endeavouros-keyring manjaro-keyring; do
            pacman -Q "$_k" >/dev/null 2>&1 && _keyrings="$_keyrings $_k"
        done
        # shellcheck disable=SC2086
        sudo pacman -Sy --needed --noconfirm $_keyrings >/dev/null 2>&1 || true
        _do_upgrade || {
            warn "Upgrade still failing. Continuing, but installs may fail."
            note "Check the pacman error above (mirror, disk space, conflict)."
        }
    fi
fi
hash -r

# ═══════════════════════════════════════════════════════════════
# [3/8] Resolve package names
# ═══════════════════════════════════════════════════════════════
# A spec is "name" or "first|second|..." (alternates). Resolution:
#   1. any candidate already satisfied locally (pacman -T, counts
#      provides, so quickshell-git satisfies quickshell)  -> have
#   2. first candidate in the official sync DBs            -> repo
#   3. first candidate on the AUR (RPC lookup via curl)    -> aur
#   4. nothing                                             -> none
step 3 "Resolving packages..."

QS_SPEC="${ZEN_QUICKSHELL_PKG:-quickshell|quickshell-git}"

TIER_CORE=(
    hyprland
    "$QS_SPEC"
    jq
    xdg-desktop-portal-hyprland
    polkit-gnome
    qt6-declarative
    qt6-wayland
    qt6-5compat
    qt6-svg
)

TIER_SYSTEM=(
    pipewire
    pipewire-pulse
    pipewire-alsa
    wireplumber
    networkmanager
    network-manager-applet
    bluez
    bluez-utils
)

TIER_ZEN=(
    "awww|swww"
    swaync
    fuzzel
    cava
    playerctl
    grim
    slurp
    wl-clipboard
    imagemagick
    alacritty
    thunar
    pavucontrol
    blueman
    zenity
    bottom
    libnotify
    nwg-displays
    nwg-look
    socat
    power-profiles-daemon
    brightnessctl
)

TIER_FONTS=(
    ttf-jetbrains-mono-nerd
    "ttf-font-awesome|otf-font-awesome"
    noto-fonts
    noto-fonts-emoji
    papirus-icon-theme
)

# 0 = on AUR, 1 = not on AUR, 2 = could not check (offline / no curl)
aur_has() {
    command -v curl >/dev/null 2>&1 || return 2
    local out
    out=$(curl -fsS --max-time 10 "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=$1" 2>/dev/null) || return 2
    echo "$out" | grep -Eq '"resultcount": ?[1-9]' && return 0
    return 1
}

R_KIND=""; R_PKG=""
resolve_spec() {
    local spec="$1" c rc
    local -a cands
    IFS='|' read -r -a cands <<< "$spec"
    R_KIND="none"; R_PKG="${cands[0]}"
    for c in "${cands[@]}"; do
        if pacman -T "$c" >/dev/null 2>&1; then R_KIND="have"; R_PKG="$c"; return; fi
    done
    for c in "${cands[@]}"; do
        if pacman -Si "$c" >/dev/null 2>&1; then R_KIND="repo"; R_PKG="$c"; return; fi
    done
    for c in "${cands[@]}"; do
        aur_has "$c"; rc=$?
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then R_KIND="aur"; R_PKG="$c"; return; fi
    done
}

PLAN_HAVE=(); PLAN_NONE=()
PLAN_REPO_CORE=(); PLAN_AUR_CORE=()
PLAN_REPO=();      PLAN_AUR=()

plan_tier() {
    local tier="$1" spec; shift
    for spec in "$@"; do
        resolve_spec "$spec"
        case "$R_KIND" in
            have) PLAN_HAVE+=("$R_PKG") ;;
            repo) if [ "$tier" = "core" ]; then PLAN_REPO_CORE+=("$R_PKG"); else PLAN_REPO+=("$R_PKG"); fi ;;
            aur)  if [ "$tier" = "core" ]; then PLAN_AUR_CORE+=("$R_PKG");  else PLAN_AUR+=("$R_PKG");  fi ;;
            none) PLAN_NONE+=("$spec") ;;
        esac
    done
}

# Guest tools per hypervisor (repo packages only, skipped on bare metal)
TIER_VM=()
case "$VIRT" in
    vmware) TIER_VM=(open-vm-tools) ;;
    oracle) TIER_VM=(virtualbox-guest-utils) ;;
    kvm|qemu) TIER_VM=(qemu-guest-agent spice-vdagent) ;;
esac

plan_tier core   "${TIER_CORE[@]}"
plan_tier system "${TIER_SYSTEM[@]}"
plan_tier zen    "${TIER_ZEN[@]}"
plan_tier fonts  "${TIER_FONTS[@]}"
[ ${#TIER_VM[@]} -gt 0 ] && plan_tier vm "${TIER_VM[@]}"

# pipewire-pulse conflicts with pulseaudio. With --noconfirm pacman
# answers "no" to the removal and the whole batch fails, so drop it
# here and say why instead.
if pacman -Q pulseaudio >/dev/null 2>&1; then
    _tmp=()
    for p in "${PLAN_REPO[@]}"; do [ "$p" = "pipewire-pulse" ] || _tmp+=("$p"); done
    if [ "${#_tmp[@]}" -ne "${#PLAN_REPO[@]}" ]; then
        PLAN_REPO=("${_tmp[@]}")
        note "pulseaudio is installed, skipping pipewire-pulse (they conflict)"
    fi
fi

TO_INSTALL=$(( ${#PLAN_REPO_CORE[@]} + ${#PLAN_AUR_CORE[@]} + ${#PLAN_REPO[@]} + ${#PLAN_AUR[@]} ))
ok "${#PLAN_HAVE[@]} already installed (skipped, --needed)"
if [ "$TO_INSTALL" -eq 0 ]; then
    ok "Nothing to install"
else
    echo "    Core from official repos : ${PLAN_REPO_CORE[*]:-(none needed)}"
    [ ${#PLAN_AUR_CORE[@]} -gt 0 ] && echo "    Core from AUR            : ${PLAN_AUR_CORE[*]}"
    echo "    Other from official repos: ${#PLAN_REPO[@]} package(s)"
    echo "    Other from AUR           : ${PLAN_AUR[*]:-(none)}"
fi
[ ${#PLAN_NONE[@]} -gt 0 ] && warn "Not found anywhere (skipped): ${PLAN_NONE[*]}"

if [ "$TO_INSTALL" -gt 0 ]; then
    echo ""
    if ! ask "    Proceed with installation? [Y/n] "; then
        echo "    Cancelled."
        exit 0
    fi
fi

# ═══════════════════════════════════════════════════════════════
# [4/8] AUR helper health check + repair
# ═══════════════════════════════════════════════════════════════
step 4 "AUR helper check..."

# A helper is only "working" if it actually executes. command -v alone
# said yes to the paru that crashed on libalpm.so.15.
helper_ok() { command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1; }

aur_build() {   # $1 = AUR pkgbase. Clones and runs makepkg -si.
    local pkg="$1" tmp rc
    sudo pacman -S --needed --noconfirm base-devel git || return 1
    tmp=$(mktemp -d) || return 1
    echo "      building $pkg from the AUR..."
    if ! git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$tmp/$pkg" >/dev/null 2>&1; then
        rm -rf "$tmp"; return 1
    fi
    [ -f "$tmp/$pkg/PKGBUILD" ] || { rm -rf "$tmp"; return 1; }
    ( cd "$tmp/$pkg" && makepkg -si --noconfirm --cleanbuild )
    rc=$?
    rm -rf "$tmp"
    hash -r
    return $rc
}

AUR_HELPER=""
BROKEN_HELPERS=()
for h in paru yay; do
    if helper_ok "$h"; then
        AUR_HELPER="$h"; break
    elif command -v "$h" >/dev/null 2>&1; then
        BROKEN_HELPERS+=("$h")
    fi
done

REBUILT=()
if [ -z "$AUR_HELPER" ] && [ ${#BROKEN_HELPERS[@]} -gt 0 ]; then
    for h in "${BROKEN_HELPERS[@]}"; do
        bad "$h is installed but cannot run:"
        "$h" --version 2>&1 | head -1 | sed 's/^/        /'
        owner=$(pacman -Qoq "$(command -v "$h")" 2>/dev/null | head -1)
        owner="${owner:-$h}"
        note "Cause: $owner was built against an older pacman library."
        note "Rebuilding $owner against libalpm.so.${LIBALPM_NOW:-?} ..."
        REBUILT+=("$owner")
        if aur_build "$owner" && helper_ok "$h"; then
            AUR_HELPER="$h"
            ok "$h repaired ($owner rebuilt)"
            break
        fi
        warn "Rebuilding $owner did not fix it."
    done
fi

NEED_AUR=$(( ${#PLAN_AUR_CORE[@]} + ${#PLAN_AUR[@]} ))

if [ -z "$AUR_HELPER" ] && { [ "$NEED_AUR" -gt 0 ] || [ ${#BROKEN_HELPERS[@]} -gt 0 ]; }; then
    if [ ${#BROKEN_HELPERS[@]} -eq 0 ]; then
        echo "    No AUR helper installed. Needed for: ${PLAN_AUR_CORE[*]} ${PLAN_AUR[*]}"
        if ask "    Install paru now? [Y/n] "; then
            if aur_build paru-bin && helper_ok paru; then
                AUR_HELPER="paru"; ok "paru installed"
            fi
        fi
    fi
    # Last resort: yay from source. Go builds in about a minute and
    # links against whatever libalpm is installed right now.
    if [ -z "$AUR_HELPER" ]; then
        yown=$(pacman -Qq yay yay-bin yay-git 2>/dev/null | head -1)
        case " ${REBUILT[*]} " in *" yay "*) yown="__done__" ;; esac
        if [ "$yown" != "__done__" ]; then
            if [ -n "$yown" ] && [ "$yown" != "yay" ]; then
                note "Removing broken $yown so yay can be built from source"
                sudo pacman -Rns --noconfirm "$yown" >/dev/null 2>&1 || true
            fi
            note "Fallback: building yay from source..."
            if aur_build yay && helper_ok yay; then
                AUR_HELPER="yay"; ok "yay built from source and working"
            fi
        fi
    fi
fi

if [ -n "$AUR_HELPER" ]; then
    ok "AUR helper: $AUR_HELPER ($("$AUR_HELPER" --version 2>/dev/null | head -1))"
elif [ "$NEED_AUR" -gt 0 ]; then
    warn "No working AUR helper. AUR packages will be skipped:"
    note "${PLAN_AUR_CORE[*]} ${PLAN_AUR[*]}"
    note "Hyprland + Quickshell still install from the official repos."
else
    ok "No AUR packages needed, helper not required"
fi

aur_install() {
    case "$AUR_HELPER" in
        paru) paru -S --needed --noconfirm --skipreview "$@" ;;
        yay)  yay  -S --needed --noconfirm --answerdiff None --answerclean None "$@" ;;
        *)    return 1 ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# [5/8] Install
# ═══════════════════════════════════════════════════════════════
step 5 "Installing packages..."

INSTALLED=(); FAILED=(); SKIPPED=()
[ "$TO_INSTALL" -eq 0 ] && ok "Everything already present, nothing to do"

# The hyprland package owns /usr/share/wayland-sessions/hyprland.desktop.
# An unowned copy (left by the old bootstrap) makes pacman abort with
# "exists in filesystem". Move it aside before installing hyprland.
fix_stale_session_file() {
    local f="/usr/share/wayland-sessions/hyprland.desktop"
    [ -e "$f" ] || return 0
    pacman -Qo "$f" >/dev/null 2>&1 && return 0
    local dst
    dst="/var/tmp/zen-stale-hyprland.desktop.$(date +%Y%m%d-%H%M%S)"
    # Fallbacks: a name without .desktop is ignored by every display
    # manager, and removing it is fine too (it only ever held Exec=Hyprland).
    if sudo mv "$f" "$dst" 2>/dev/null \
       || { dst="$f.zen-stale"; sudo mv -f "$f" "$dst" 2>/dev/null; } \
       || { dst="(deleted)"; sudo rm -f "$f"; }; then
        warn "Moved stale session entry out of the way (was blocking pacman):"
        note "$f  ->  $dst"
    else
        bad "Could not move $f. Remove it manually, then re-run:"
        note "sudo rm $f"
    fi
}

# Batch install, then one-by-one retry so one bad name or conflict
# only skips that single package.
repo_install() {   # $1 label, rest = packages
    local label="$1" p; shift
    [ $# -eq 0 ] && return 0
    echo ""
    echo "    ${C_DIM}── $label: $*${C_END}"
    if sudo pacman -S --needed --noconfirm "$@"; then
        INSTALLED+=("$@"); return 0
    fi
    warn "Batch failed, retrying one by one..."
    for p in "$@"; do
        if sudo pacman -S --needed --noconfirm "$p" >/dev/null 2>&1; then
            INSTALLED+=("$p"); ok "$p"
        else
            FAILED+=("$p"); bad "$p (run: sudo pacman -S $p   to see why)"
        fi
    done
}

aur_install_list() {   # $1 label, rest = packages
    local label="$1" p; shift
    [ $# -eq 0 ] && return 0
    if [ -z "$AUR_HELPER" ]; then
        SKIPPED+=("$@"); return 0
    fi
    echo ""
    echo "    ${C_DIM}── $label (AUR via $AUR_HELPER): $*${C_END}"
    if aur_install "$@"; then
        INSTALLED+=("$@"); return 0
    fi
    warn "AUR batch failed, retrying one by one..."
    for p in "$@"; do
        if aur_install "$p"; then INSTALLED+=("$p"); ok "$p"
        else FAILED+=("$p"); bad "$p"; fi
    done
}

case " ${PLAN_REPO_CORE[*]} ${PLAN_AUR_CORE[*]} " in
    *" hyprland "*) fix_stale_session_file ;;
esac

repo_install "Core (official repos)" "${PLAN_REPO_CORE[@]}"
aur_install_list "Core" "${PLAN_AUR_CORE[@]}"

# Quickshell safety net: an AUR quickshell that failed or was skipped
# falls back to the official package.
if ! have_cmd quickshell qs && pacman -Si quickshell >/dev/null 2>&1; then
    note "Quickshell still missing, installing extra/quickshell as fallback"
    repo_install "Quickshell fallback" quickshell
fi

repo_install "System + Zen Shell + fonts (official repos)" "${PLAN_REPO[@]}"
aur_install_list "Extras" "${PLAN_AUR[@]}"
hash -r

# ═══════════════════════════════════════════════════════════════
# [6/8] Verify the core
# ═══════════════════════════════════════════════════════════════
step 6 "Verifying core components..."

CORE_BAD=()
if have_cmd Hyprland hyprland; then ok "Hyprland  $(command -v Hyprland 2>/dev/null || command -v hyprland)"
else CORE_BAD+=("hyprland"); bad "Hyprland binary not found"; fi
if have_cmd hyprctl;             then ok "hyprctl   $(command -v hyprctl)"
else CORE_BAD+=("hyprctl");  bad "hyprctl not found"; fi
if have_cmd quickshell qs;       then ok "Quickshell $(command -v quickshell 2>/dev/null || command -v qs)"
else CORE_BAD+=("quickshell"); bad "Quickshell not found"; fi
if have_cmd jq;                  then ok "jq        $(command -v jq)"
else CORE_BAD+=("jq");       bad "jq not found"; fi

if [ ${#CORE_BAD[@]} -gt 0 ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║   BOOTSTRAP INCOMPLETE: core packages are missing             ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "    Missing: ${CORE_BAD[*]}"
    echo ""
    echo "    These are official-repo packages, so no AUR helper is needed."
    echo "    Run this and read the exact pacman error:"
    echo ""
    echo "        sudo pacman -Syu hyprland quickshell jq"
    echo ""
    echo "    No login-session entry was created, so the login screen will"
    echo "    not offer a Hyprland that cannot start."
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# [7/8] Login session entry
# ═══════════════════════════════════════════════════════════════
step 7 "Hyprland login session entry..."

SESS_DIR="/usr/share/wayland-sessions"
HYPR_EXEC="$(command -v start-hyprland 2>/dev/null || command -v Hyprland 2>/dev/null || command -v hyprland)"
VALID_SESSION=0
shopt -s nullglob
for s in "$SESS_DIR"/*yprland*.desktop; do
    exec_line=$(grep -m1 '^Exec=' "$s" | cut -d= -f2-)
    bin="${exec_line%% *}"
    name=$(grep -m1 '^Name=' "$s" | cut -d= -f2-)
    if [ -n "$bin" ] && command -v "$bin" >/dev/null 2>&1; then
        ok "\"$name\" ($(basename "$s")) -> $bin"
        VALID_SESSION=1
    else
        warn "\"$name\" ($(basename "$s")) needs '$bin', which is not installed."
        note "Do NOT pick \"$name\" at the login screen."
    fi
done
shopt -u nullglob

if [ "$VALID_SESSION" = "0" ]; then
    SESSION_FILE="$SESS_DIR/zen-hyprland.desktop"
    echo "    No usable Hyprland session entry. Creating $SESSION_FILE"
    sudo mkdir -p "$SESS_DIR"
    sudo tee "$SESSION_FILE" >/dev/null <<EOF
[Desktop Entry]
Name=Hyprland
Comment=Hyprland with ZenithArch Shell
Exec=$HYPR_EXEC
Type=Application
DesktopNames=Hyprland
EOF
    ok "Created. Hyprland now shows at the login screen."
fi

# ═══════════════════════════════════════════════════════════════
# [8/8] Base Hyprland config + VM notes
# ═══════════════════════════════════════════════════════════════
step 8 "Hyprland base config..."

HYPR_DIR="$HOME/.config/hypr"
HYPR_CONF="$HYPR_DIR/hyprland.conf"

if [ -f "$HYPR_CONF" ]; then
    ok "$HYPR_CONF already exists, leaving it alone"
else
    echo "    No Hyprland config yet. Writing a minimal default..."
    mkdir -p "$HYPR_DIR/modules"
    cat > "$HYPR_CONF" <<'EOF'
# ═══════════════════════════════════════════════════════════════
# Minimal Hyprland config, bootstrapped by ZenithArch Shell.
# install.sh layers the full Zen Shell config on top of this.
# ═══════════════════════════════════════════════════════════════

monitor = , preferred, auto, 1

env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = QT_QPA_PLATFORM,wayland
env = QT_WAYLAND_DISABLE_WINDOWDECORATION,1

exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = swww-daemon || awww-daemon
exec-once = swaync
exec-once = nm-applet --indicator
exec-once = blueman-applet

input {
    kb_layout = us
    follow_mouse = 1
    touchpad {
        natural_scroll = true
    }
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
    col.active_border = rgba(5A4F42ff) rgba(928572ff) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

decoration {
    rounding = 8
    blur {
        enabled = true
        size = 6
        passes = 2
    }
}

animations {
    enabled = true
}

dwindle {
    preserve_split = true
}

# Minimal binds. install.sh adds the full Zen Shell set.
bind = SUPER, Return, exec, alacritty
bind = SUPER, Q, killactive
bind = SUPER, M, exit
bind = SUPER, E, exec, thunar
bind = SUPER, V, togglefloating
bind = SUPER, R, exec, fuzzel
bind = SUPER, F, fullscreen

bind = SUPER, left,  movefocus, l
bind = SUPER, right, movefocus, r
bind = SUPER, up,    movefocus, u
bind = SUPER, down,  movefocus, d

bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
bind = SUPER, 3, workspace, 3
bind = SUPER, 4, workspace, 4
bind = SUPER, 5, workspace, 5

bind = SUPER SHIFT, 1, movetoworkspace, 1
bind = SUPER SHIFT, 2, movetoworkspace, 2
bind = SUPER SHIFT, 3, movetoworkspace, 3
bind = SUPER SHIFT, 4, movetoworkspace, 4
bind = SUPER SHIFT, 5, movetoworkspace, 5

bindm = SUPER, mouse:272, movewindow
bindm = SUPER, mouse:273, resizewindow

# Zen Shell startup comes from autostart.conf (added by install.sh).
# Do NOT add 'exec-once = quickshell ...' here, it would double-launch.
EOF
    if [ -n "$VIRT" ]; then
        cat >> "$HYPR_CONF" <<EOF

# Virtual machine ($VIRT): virtual GPUs have no usable hardware cursor,
# and their DRM drivers do poorly with buffer modifiers.
env = AQ_NO_MODIFIERS,1
cursor {
    no_hardware_cursors = true
}
EOF
    fi
    ok "$HYPR_CONF written"
fi

if [ -n "$VIRT" ]; then
    echo ""
    warn "Running inside a VM ($VIRT). Hyprland needs GPU acceleration:"
    case "$VIRT" in
        vmware)
            note "VMware: VM Settings > Display > tick 'Accelerate 3D graphics'"
            note "(power the VM off first). Optional: sudo pacman -S open-vm-tools" ;;
        oracle)
            note "VirtualBox: Display > Graphics Controller VMSVGA + Enable 3D Acceleration" ;;
        kvm|qemu)
            note "QEMU/KVM: use virtio-gpu with 3D (virgl) enabled" ;;
        *)
            note "Enable 3D / GPU acceleration in the VM display settings" ;;
    esac
    if ! compgen -G "/dev/dri/renderD*" >/dev/null 2>&1; then
        warn "No /dev/dri/renderD* node found. 3D acceleration looks OFF,"
        note "so Hyprland will likely exit right after login until you enable it."
    fi
    if [ "$VIRT" = "vmware" ] && pacman -Q open-vm-tools >/dev/null 2>&1 \
       && ! systemctl is-enabled --quiet vmtoolsd 2>/dev/null; then
        sudo systemctl enable --now vmtoolsd >/dev/null 2>&1 \
            && ok "vmtoolsd enabled (open-vm-tools)"
    fi
    note "If login bounces back to the greeter:  ./bootstrap.sh --doctor"
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║            ZEN SHELL BOOTSTRAP COMPLETE                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
ok "Core verified: Hyprland, hyprctl, Quickshell, jq"
[ ${#INSTALLED[@]} -gt 0 ] && note "Installed / verified this run: ${#INSTALLED[@]} package(s)"
[ ${#FAILED[@]}    -gt 0 ] && warn "Failed (non-core, shell still runs): ${FAILED[*]}"
[ ${#SKIPPED[@]}   -gt 0 ] && warn "Skipped, no working AUR helper: ${SKIPPED[*]}"
[ ${#PLAN_NONE[@]} -gt 0 ] && warn "Not found in repos or AUR: ${PLAN_NONE[*]}"

if [ "${ZEN_BOOTSTRAP_AUTO:-0}" = "1" ]; then
    # Called by install.sh, which continues with the shell install.
    echo ""
    note "Returning to install.sh..."
    exit 0
fi

echo ""
echo "  Next:"
echo "    1. Run:  cd $SCRIPT_DIR && ./install.sh"
echo "    2. Log out of $CURRENT_DE"
echo "    3. At the login screen (${DM_RUNNING:-your display manager}) pick \"Hyprland\""
echo ""
exit 0
