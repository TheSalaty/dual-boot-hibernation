#!/usr/bin/env bash
# Freeze Linux and boot Windows ONCE on the next start; afterwards GRUB reverts
# to your normal default (Linux). Unmounts shared NTFS/Steam drives first (to
# avoid corruption while Windows writes to them). If a drive is busy, a
# shutdown-style dialog offers to kill the blocking apps and continue, or cancel.
#
# Deps: zenity lsof psmisc libnotify   (see README, Part 5)
# Requires GRUB built with GRUB_DEFAULT=saved (install.sh sets this up).
set -uo pipefail

# --- Configuration -----------------------------------------------------------
# install.sh writes the detected values to the config file below. For a manual
# install, either create that file or edit the defaults here directly.
#
#   WIN_ENTRY : exact Windows GRUB menu title
#               sudo grep -i "menuentry '" /boot/grub/grub.cfg | cut -d"'" -f2
#   DRIVES    : shared NTFS mount points to unmount first (empty () if none)

WIN_ENTRY="Windows Boot Manager"
DRIVES=()

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/hibernate-windows.conf"
# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"

TITLE="Hibernate → Windows"

# Unmount one drive; on "busy" show a dialog listing the blocking processes.
# return 0 = unmounted/not needed, 1 = cancelled/failed.
unmount_or_ask() {
    local m="$1" list
    mountpoint -q "$m" || return 0
    sudo umount "$m" 2>/dev/null && return 0

    while true; do
        list=$(lsof -w "$m" 2>/dev/null | awk 'NR>1 {print "• "$1"  (PID "$2", "$3")"}' | sort -u)
        [ -z "$list" ] && list="• (unknown processes)"

        if zenity --question --title="$TITLE" --width=460 \
            --icon-name=drive-harddisk \
            --ok-label="Kill & continue" --cancel-label="Cancel" \
            --text="<b>$m</b> is still busy and cannot be unmounted.

These processes are using it:
$list

<i>Killing forces them closed (unsaved progress is lost).</i>"
        then
            fuser -km "$m" 2>/dev/null
            sudo fuser -km "$m" 2>/dev/null
            sleep 2
            sudo umount "$m" 2>/dev/null && return 0
        else
            return 1
        fi
    done
}

for m in "${DRIVES[@]}"; do
    if ! unmount_or_ask "$m"; then
        notify-send "$TITLE" "Cancelled — Linux keeps running normally." 2>/dev/null || true
        exit 1
    fi
done

if ! sudo grub-reboot "$WIN_ENTRY"; then
    zenity --error --title="$TITLE" --width=400 \
        --text="Could not set the next boot to Windows (grub-reboot)." 2>/dev/null || true
    exit 1
fi

# systemctl hibernate only returns AFTER resume (exit 0). If freezing fails, the
# one-shot Windows boot would linger -> reset it so the next reboot stays Linux.
if ! systemctl hibernate; then
    sudo grub-editenv - unset next_entry 2>/dev/null
    zenity --error --title="$TITLE" --width=400 \
        --text="Hibernation failed – the one-shot Windows boot was reset. Linux keeps running." 2>/dev/null || true
    exit 1
fi
