#!/usr/bin/env bash
#
# install.sh — guided setup for the Linux ⇄ Windows hibernate handoff.
#
# Detects the system, asks which parts you want, and runs one module from
# install/ per part. Every edited system file gets a *.bak.TIMESTAMP backup, and
# the report at the end says where to continue if something failed.
#
# Run it as your normal user (NOT root); it uses sudo where needed.
#   ./install.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the modules
GUIDE="docs/setup-guide.md"
# shellcheck disable=SC2034
EXT_UUID="hibernate-windows@dualboot"

# shellcheck source=install/lib.sh
. "$HERE/install/lib.sh"

module() {
    # shellcheck source=/dev/null
    . "$HERE/install/$1.sh"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
banner "Dual-boot hibernate handoff — installer"

if [ "$(id -u)" -eq 0 ]; then
    err "Please run as your normal user, not root (the script uses sudo itself)."
    exit 1
fi
if ! command -v pacman >/dev/null; then
    err "This installer is written for Arch-based systems and needs pacman."
    info "The ideas apply to any distribution — see $GUIDE and docs/how-it-works.md."
    exit 1
fi

_missing=""
for _t in awk sed grep findmnt lsblk df; do
    command -v "$_t" >/dev/null || _missing="$_missing $_t"
done
if [ -n "$_missing" ]; then
    err "Missing core tools:$_missing — install them and re-run."
    exit 1
fi

section "Detecting your system"
UEFI=no;   [ -d /sys/firmware/efi ] && UEFI=yes
ROOT_FS=$(findmnt -no FSTYPE / 2>/dev/null)
RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
RAM_MIB=$(( (RAM_KB + 1023) / 1024 ))
RAM_GB=$(( (RAM_KB + 1048575) / 1048576 ))
HAS_GRUB=no; { [ -f /boot/grub/grub.cfg ] || command -v grub-mkconfig >/dev/null; } && HAS_GRUB=yes
IS_GNOME=no; { echo "${XDG_CURRENT_DESKTOP:-}" | grep -qi gnome || command -v gnome-shell >/dev/null; } && IS_GNOME=yes
IMMUTABLE=no; command -v steamos-readonly >/dev/null && IMMUTABLE=yes

info "UEFI firmware .......... $UEFI"
info "Root filesystem ........ ${ROOT_FS:-unknown}"
info "RAM .................... ${RAM_GB} GB (${RAM_MIB} MiB)"
info "Boot loader is GRUB .... $HAS_GRUB"
info "GNOME desktop .......... $IS_GNOME (session: ${XDG_SESSION_TYPE:-unknown})"
[ "$IMMUTABLE" = yes ] && warn "Image-based system (SteamOS): untested, see docs/steamos.md."

if [ "$UEFI" != yes ]; then
    err "No UEFI firmware detected. The handoff selects Windows through UEFI boot entries."
    exit 1
fi

echo
warn "Depending on your choices this edits /etc/default/grub, /etc/fstab and"
warn "/etc/mkinitcpio.conf and rebuilds GRUB / the initramfs. Backups are made."
ask_yn "Continue?" y || { echo "Aborted."; exit 0; }

sudo -v || { err "sudo authentication failed."; exit 1; }

# Keep the sudo timestamp warm so the long swap-file write never stalls on a
# password prompt. Stops itself when this script exits.
( while true; do sudo -n true 2>/dev/null; sleep 45; kill -0 "$$" 2>/dev/null || exit 0; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# ---------------------------------------------------------------------------
# Choose modules
# ---------------------------------------------------------------------------
section "Choose what to install"

DO_HIBERNATE=no; DO_SB=no
if [ "$HAS_GRUB" = yes ] && [ "$IMMUTABLE" = no ]; then
    ask_yn "Set up hibernation (swap file + resume settings)?" y && DO_HIBERNATE=yes

    SB_STATE="unknown"
    command -v sbctl >/dev/null && SB_STATE=$(sbctl status 2>/dev/null | awk -F'\t' '/Secure Boot/{print $NF}')
    MOK_STATE=$(mokutil --sb-state 2>/dev/null || true)
    info "Current Secure Boot: ${SB_STATE:-unknown} ${MOK_STATE:+($MOK_STATE)}"
    if echo "$MOK_STATE $SB_STATE" | grep -qiE 'enabled'; then
        info "Secure Boot already appears enabled — you may not need this module."
        ask_yn "Set up Secure Boot with your own keys (sbctl) anyway?" n && DO_SB=yes
    else
        ask_yn "Set up Secure Boot with your own keys (sbctl)?" y && DO_SB=yes
    fi
else
    info "Hibernation and Secure Boot setup are automated for GRUB on a writable"
    info "system only. Set them up by hand ($GUIDE) — os-switch itself still works."
fi

DO_MOUNT=no
# NTFS data partitions; the Windows recovery partition is not one.
WINRE_TYPE=de94bba4-06d1-4d40-a16a-bfd50179d6ac
mapfile -t NTFS_AVAIL < <(lsblk -rno NAME,FSTYPE,UUID,PARTTYPE,LABEL 2>/dev/null |
    awk -v rec="$WINRE_TYPE" '($2=="ntfs"||$2=="ntfs3") && tolower($4)!=rec {
        l=$1" "$2" "$3; for(i=5;i<=NF;i++) l=l" "$i; print l}')
if [ "${#NTFS_AVAIL[@]}" -gt 0 ]; then
    ask_yn "Mount Windows/NTFS data drives at boot (handy for a shared Steam library)?" y && DO_MOUNT=yes
else
    info "No NTFS partitions found → skipping the mount question."
fi

DO_OSW=no; ask_yn "Install os-switch (the handoff command)?" y && DO_OSW=yes
DO_EXT=no
if [ "$IS_GNOME" = yes ]; then
    ask_yn "Install the GNOME power-menu extension?" y && DO_EXT=yes
else
    info "GNOME not detected → skipping the extension. Bind 'os-switch windows' to a key or menu entry of your desktop."
fi

[ "$DO_HIBERNATE" = yes ] && module 10-hibernation
[ "$DO_SB" = yes ]        && module 20-secureboot
[ "$DO_MOUNT" = yes ]     && module 30-mounts
[ "$DO_OSW" = yes ]       && module 40-os-switch
[ "$DO_EXT" = yes ]       && module 50-gnome-extension

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
banner "Installation report"
printf '\n'
FAILS=0; MANUAL=0
for i in "${!RES_NAME[@]}"; do
    n="${RES_NAME[$i]}"; s="${RES_STATUS[$i]}"; note="${RES_NOTE[$i]}"
    case "$s" in
        OK)          printf '  %s✓%s %-22s %sdone%s\n' "$GRN" "$R" "$n" "$GRN" "$R" ;;
        OK-REBOOT)   printf '  %s✓%s %-22s %sdone — reboot to activate%s\n' "$GRN" "$R" "$n" "$YLW" "$R"; MANUAL=$((MANUAL+1)) ;;
        OK-UEFI)     printf '  %s✓%s %-22s %sdone — enable Secure Boot in UEFI%s\n' "$GRN" "$R" "$n" "$YLW" "$R"; MANUAL=$((MANUAL+1)) ;;
        OK-RELOGIN)  printf '  %s✓%s %-22s %sdone — log out/in then enable%s\n' "$GRN" "$R" "$n" "$YLW" "$R"; MANUAL=$((MANUAL+1)) ;;
        WARN)        printf '  %s!%s %-22s %sneeds attention%s\n' "$YLW" "$R" "$n" "$YLW" "$R"; MANUAL=$((MANUAL+1)) ;;
        SKIP)        printf '  %s·%s %-22s %sskipped%s\n' "$DIM" "$R" "$n" "$DIM" "$R" ;;
        FAIL)        printf '  %s✗%s %-22s %sfailed%s\n' "$RED" "$R" "$n" "$RED" "$R"; FAILS=$((FAILS+1)) ;;
    esac
    [ -n "$note" ] && printf '      %s↳ %s%s\n' "$DIM" "$note" "$R"
done

printf '\n'
section "Next steps"
[ "$DO_HIBERNATE" = yes ] && info "${B}Reboot${R} — required for hibernation (new initramfs + kernel command line)."
[ "$DO_SB" = yes ]        && info "After the reboot: enter UEFI and turn ${B}Secure Boot = Enabled${R}."
[ "$DO_EXT" = yes ]       && info "Log out and back in, then: ${B}gnome-extensions enable $EXT_UUID${R}"
[ "$DO_OSW" = yes ]       && info "Check the setup any time with ${B}os-switch status${R}."
info "Guide: ${B}$GUIDE${R}"

printf '\n'
if [ "$FAILS" -gt 0 ]; then
    err "Finished with $FAILS failed module(s). See the ↳ pointers above."
    exit 1
elif [ "$MANUAL" -gt 0 ]; then
    ok "All selected modules installed. A few manual steps remain (see above)."
else
    ok "All done."
fi
