#!/usr/bin/env bash
# Shared helpers for install.sh and the modules in install/. Sourced, not run.

# ---------------------------------------------------------------------------
# Pretty console output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'
else
    B=""; DIM=""; R=""; RED=""; GRN=""; YLW=""; BLU=""; CYN=""
fi

banner() {
    printf '\n%s╔══════════════════════════════════════════════════════════════╗%s\n' "$CYN" "$R"
    printf '%s║%s %-60s %s║%s\n' "$CYN" "$B" "$1" "$R$CYN" "$R"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$CYN" "$R"
}
section() { printf '\n%s▐ %s%s\n' "$BLU$B" "$1" "$R"; }
step()    { printf '  %s→%s %s\n' "$YLW" "$R" "$1"; }
ok()      { printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
warn()    { printf '  %s!%s %s\n' "$YLW" "$R" "$1"; }
err()     { printf '  %s✗%s %s\n' "$RED" "$R" "$1"; }
info()    { printf '  %s·%s %s\n' "$DIM" "$R" "$1"; }

ask_yn() {  # ask_yn "Question" default(y/n) -> returns 0 for yes
    local q="$1" def="${2:-y}" ans hint
    [ "$def" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    read -rp "  ${B}?${R} $q $hint " ans
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[YyJj] ]]
}

# ---------------------------------------------------------------------------
# Result tracking for the final report
# ---------------------------------------------------------------------------
declare -a RES_NAME RES_STATUS RES_NOTE
record() { RES_NAME+=("$1"); RES_STATUS+=("$2"); RES_NOTE+=("$3"); }

# Locate the EFI System Partition mount point (don't assume /boot/efi).
detect_esp() {
    local m
    m=$(findmnt -rno TARGET,FSTYPE 2>/dev/null \
        | awk '$2=="vfat" && ($1=="/boot/efi"||$1=="/efi"||$1=="/boot"){print $1; exit}')
    if [ -z "$m" ]; then
        for c in /boot/efi /efi /boot; do [ -d "$c/EFI" ] && { m="$c"; break; }; done
    fi
    printf '%s' "${m:-/boot/efi}"
}

STAMP=$(date +%Y%m%d-%H%M%S)
backup() { [ -f "$1" ] && sudo cp -a "$1" "$1.bak.$STAMP" && info "backup: $1.bak.$STAMP"; }

# Install packages through pacman. On an image-based system (SteamOS) the system
# partition is read-only and packages vanish with the next update, so nothing is
# installed there: the caller gets a failure and decides whether it matters.
pkg_install() {
    if command -v steamos-readonly >/dev/null && steamos-readonly status 2>/dev/null | grep -qi enabled; then
        warn "Read-only system image: not installing $* (see docs/steamos.md)."
        return 1
    fi
    sudo pacman -S --needed --noconfirm "$@" >/dev/null 2>&1
}
