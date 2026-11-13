#!/usr/bin/env bash
# Module: the os-switch command, its root helper and the units around
# hibernation. Sourced by install.sh.
# shellcheck disable=SC2154  # variables come from install.sh

banner "os-switch — the handoff command"
osw_ok=yes
BIN=/usr/local/bin/os-switch
CONF=/etc/os-switch.conf
UNIT_DIR=/etc/systemd/system

pkg_install efibootmgr || command -v efibootmgr >/dev/null || { err "efibootmgr is missing"; osw_ok=no; }
# Dialogs and notifications are optional: without them os-switch asks on the
# terminal and refuses anything destructive when there is none.
pkg_install zenity libnotify || info "no dialog tools installed — questions appear on the terminal only"

# ---------------------------------------------------------------------------
section "Installing the command"
SRC=""
for c in "$HERE/os-switch" "$HERE/target/release/os-switch"; do
    [ -x "$c" ] && { SRC="$c"; break; }
done
if [ -z "$SRC" ] && command -v cargo >/dev/null; then
    step "Building from source (cargo build --release)…"
    ( cd "$HERE" && cargo build --release >/dev/null 2>&1 ) && SRC="$HERE/target/release/os-switch"
fi
if [ -n "$SRC" ]; then
    sudo install -D -m 0755 -o root -g root "$SRC" "$BIN" && ok "installed $BIN"
else
    err "No os-switch binary next to install.sh and no cargo to build one."
    info "Download the release archive, or install Rust and re-run."
    osw_ok=no
fi

if [ "$osw_ok" = yes ]; then
    if [ -f "$CONF" ]; then
        info "keeping existing $CONF"
    else
        sudo tee "$CONF" >/dev/null <<'EOF'
# os-switch settings. Remove the leading "#" to change a value.

# What happens once the session is frozen:
#   rtc       power off; the clock switches the machine back on (default).
#             This is the kernel's regular way to hibernate.
#   reboot    restart straight into Windows. A few seconds faster, but the
#             kernel skips steps for it and it hangs on some machines, for
#             example with the proprietary Nvidia driver.
#   poweroff  power off and wait for the power button
#after_freeze = rtc

# How Windows is selected:
#   efi   firmware boot entries (default)
#   grub  a flag on the EFI partition, for firmware that ignores one-time entries
#backend = efi

# Firmware entry number of Windows (see `efibootmgr`). Detected when unset.
#windows_entry = 0000

# Keep starting Windows until Windows asks for Linux again. Needs the Windows
# companion; without it you would have to use the firmware boot menu to return.
#sticky = no

# Lock the screen before freezing.
#lock_screen = yes

# Timing of the clock wake-up (after_freeze = rtc): base seconds, plus tenths of
# a second per GiB of hibernation image. A wake-up that comes too early cancels
# the hibernation; os-switch then adds time by itself and tries again.
#rtc_base_secs = 25
#rtc_tenths_per_gb = 20
EOF
        ok "wrote $CONF"
    fi

    # -----------------------------------------------------------------------
    section "Root helper without a password"
    # One rule for one program. The helper accepts a fixed set of actions and
    # validates every argument itself.
    SUDOERS=/etc/sudoers.d/os-switch
    echo "$USER ALL=(root) NOPASSWD: $BIN helper *" | sudo tee "$SUDOERS" >/dev/null
    sudo chmod 440 "$SUDOERS"
    if sudo visudo -cf "$SUDOERS" >/dev/null 2>&1; then
        ok "sudo rule valid"
    else
        err "sudo rule invalid — removing it"; sudo rm -f "$SUDOERS"; osw_ok=no
    fi

    # -----------------------------------------------------------------------
    section "Units around hibernation"
    # Units in /etc instead of a system-sleep hook in /usr, so the setup also
    # survives on systems whose /usr is replaced by updates.
    sudo tee "$UNIT_DIR/os-switch-pre-sleep.service" >/dev/null <<EOF
[Unit]
Description=os-switch: prepare the clock wake-up before hibernating
Before=sleep.target

[Service]
Type=oneshot
ExecStart=$BIN helper sleep-hook pre

[Install]
WantedBy=hibernate.target
EOF
    sudo tee "$UNIT_DIR/os-switch-resume.service" >/dev/null <<EOF
[Unit]
Description=os-switch: make Linux the default again and remount drives after waking
After=hibernate.target

[Service]
Type=oneshot
ExecStart=$BIN helper sleep-hook post

[Install]
WantedBy=hibernate.target
EOF
    sudo tee "$UNIT_DIR/os-switch-boot.service" >/dev/null <<EOF
[Unit]
Description=os-switch: make Linux the default again after a cold start
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$BIN helper trip-end

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    if sudo systemctl enable os-switch-pre-sleep.service os-switch-resume.service os-switch-boot.service >/dev/null 2>&1; then
        ok "units enabled"
    else
        err "could not enable the units"; osw_ok=no
    fi
fi

# ---------------------------------------------------------------------------
# GRUB fallback, only on request.
if [ "$osw_ok" = yes ] && [ "$HAS_GRUB" = yes ] \
    && ask_yn "Use the GRUB fallback? Only if your firmware ignores one-time boot entries" n; then
    section "GRUB fallback"
    ESP=$(detect_esp)
    LINUX_ESP_UUID=$(findmnt -no UUID "$ESP" 2>/dev/null)
    WIN_ESP_UUID=""
    [ -f "$ESP/EFI/Microsoft/Boot/bootmgfw.efi" ] && WIN_ESP_UUID="$LINUX_ESP_UUID"
    if [ -z "$WIN_ESP_UUID" ]; then
        info "The Windows boot manager is not on $ESP. EFI partitions on this machine:"
        lsblk -rno NAME,SIZE,FSTYPE,UUID | awk '$3=="vfat"{print "      /dev/"$1"  "$2"  "$4}'
        read -rp "  ${B}?${R} UUID of the Windows EFI partition: " WIN_ESP_UUID
    fi
    if [ -n "$LINUX_ESP_UUID" ] && [[ "$WIN_ESP_UUID" =~ ^[0-9A-Fa-f-]+$ ]]; then
        # Runs before the Linux entries. GRUB clears the flag first and only
        # then starts Windows, so a failure can never trap the machine there.
        sudo tee /etc/grub.d/09_os_switch >/dev/null <<EOF
#!/bin/sh
cat <<'GRUB'
search --no-floppy --fs-uuid --set=os_switch_esp $LINUX_ESP_UUID
if [ -f (\$os_switch_esp)/EFI/os-switch/grubenv ]; then
  load_env --file (\$os_switch_esp)/EFI/os-switch/grubenv os_switch_windows
  if [ "\$os_switch_windows" = "1" ]; then
    set os_switch_windows=0
    if save_env --file (\$os_switch_esp)/EFI/os-switch/grubenv os_switch_windows; then
      search --no-floppy --fs-uuid --set=root $WIN_ESP_UUID
      chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      boot
    fi
  fi
fi
GRUB
EOF
        sudo chmod 755 /etc/grub.d/09_os_switch
        if sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then
            sudo sed -i -E '/^\s*#?\s*backend\s*=/d' "$CONF"
            echo 'backend = grub' | sudo tee -a "$CONF" >/dev/null
            ok "GRUB fallback installed (backend = grub)"
        else
            err "grub-mkconfig failed"; osw_ok=no
        fi
    else
        err "Could not determine the EFI partition UUIDs — GRUB fallback not installed."; osw_ok=no
    fi
fi

# ---------------------------------------------------------------------------
section "Removing version 1"
removed=no
gone() { ok "removed $1"; removed=yes; }
for f in "$HOME/.local/bin/hibernate-windows.sh" "${XDG_CONFIG_HOME:-$HOME/.config}/hibernate-windows.conf"; do
    [ -e "$f" ] && rm -f "$f" && gone "$f"
done
if [ -e "$UNIT_DIR/hibernate-windows-reset-mode.service" ]; then
    sudo systemctl disable hibernate-windows-reset-mode.service >/dev/null 2>&1
    sudo rm -f "$UNIT_DIR/hibernate-windows-reset-mode.service" && gone "hibernate-windows-reset-mode.service"
fi
for f in /etc/sudoers.d/hibernate-windows /usr/local/sbin/hibernate-windows-boot-mode \
    /usr/lib/systemd/system-sleep/remount-steam-drives \
    /etc/systemd/sleep.conf.d/90-hibernate-windows-reboot.conf; do
    sudo test -e "$f" && sudo rm -f "$f" && gone "$f"
done
# Version 1 selected Windows through a GRUB menu title. GRUB cannot clear that
# on Btrfs, so a stale one may still be stored.
if command -v grub-editenv >/dev/null && sudo grub-editenv - list 2>/dev/null | grep -q '^next_entry='; then
    sudo grub-editenv - unset next_entry && gone "stale GRUB next_entry"
fi
[ "$removed" = no ] && info "nothing from version 1 found"

if [ "$osw_ok" = yes ]; then
    section "Check"
    "$BIN" status || warn "status reports open points (see above)"
    record "os-switch" "OK" "Try it: os-switch reboot-windows"
else
    record "os-switch" "FAIL" "docs/how-it-works.md"
fi
