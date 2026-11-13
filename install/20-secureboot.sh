#!/usr/bin/env bash
# Module: Secure Boot with your own keys (sbctl). Sourced by install.sh.
# shellcheck disable=SC2154  # variables come from install.sh

banner "Secure Boot with your own keys (sbctl)"
sb_ok=yes
step "Ensuring sbctl is installed…"
pkg_install sbctl || { err "could not install sbctl"; sb_ok=no; }

if [ "$sb_ok" = yes ]; then
    SETUP=$(sbctl status 2>/dev/null | awk -F'\t' '/Setup Mode/{print $NF}')
    info "Setup Mode: ${SETUP:-unknown}"
    if ! echo "$SETUP" | grep -qi enabled; then
        warn "Firmware is NOT in Setup Mode. Enroll may fail."
        warn "If it does: reboot → UEFI → clear/reset Secure Boot keys (enter Setup Mode), then re-run."
    fi

    [ -d /var/lib/sbctl/keys ] && info "keys already exist" || { step "Creating keys…"; sudo sbctl create-keys >/dev/null 2>&1 && ok "keys created" || { err "create-keys failed"; sb_ok=no; }; }
fi

if [ "$sb_ok" = yes ]; then
    ESP=$(detect_esp)
    info "EFI System Partition: $ESP"
    if [ ! -d "$ESP/EFI" ]; then
        err "No EFI directory under $ESP — cannot locate the bootloader. Skipping Secure Boot."
        sb_ok=no
    fi
fi

if [ "$sb_ok" = yes ]; then
    GRUBX=$(sudo find "$ESP/EFI" -maxdepth 2 -iname grubx64.efi 2>/dev/null | grep -vi '/Boot/' | head -1)
    BID=$(basename "$(dirname "$GRUBX")" 2>/dev/null)
    [ -z "$BID" ] && BID="GRUB"
    info "GRUB EFI id: $BID"

    section "Removing GRUB shim_lock (the 'prohibited by secure boot policy' trap)"
    backup /etc/default/grub
    grep -q '^GRUB_DISABLE_SHIM_LOCK=y' /etc/default/grub || echo 'GRUB_DISABLE_SHIM_LOCK=y' | sudo tee -a /etc/default/grub >/dev/null
    step "grub-install --disable-shim-lock (standard + removable)…"
    sudo grub-install --target=x86_64-efi --efi-directory="$ESP" --bootloader-id="$BID" --modules="tpm" --disable-shim-lock >/dev/null 2>&1 \
        && sudo grub-install --target=x86_64-efi --efi-directory="$ESP" --removable --modules="tpm" --disable-shim-lock >/dev/null 2>&1 \
        && ok "GRUB reinstalled without shim_lock" || { err "grub-install failed"; sb_ok=no; }
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1

    section "Signing your EFI binaries"
    for f in "$ESP/EFI/$BID/grubx64.efi" "$ESP/EFI/Boot/bootx64.efi" /boot/vmlinuz-*; do
        [ -e "$f" ] || continue
        sudo sbctl sign -s "$f" >/dev/null 2>&1 && ok "signed $(basename "$f")" || warn "could not sign $f"
    done

    section "Enrolling keys (with Microsoft keys for dual-boot)"
    if ! sudo sbctl enroll-keys -m >/dev/null 2>&1; then
        warn "enroll failed — clearing immutable flag on efivars and retrying…"
        sudo chattr -i /sys/firmware/efi/efivars/PK-* /sys/firmware/efi/efivars/KEK-* /sys/firmware/efi/efivars/db-* 2>/dev/null
        sudo sbctl enroll-keys -m >/dev/null 2>&1 && ok "keys enrolled" || { err "enroll-keys failed"; sb_ok=no; }
    else
        ok "keys enrolled (with -m)"
    fi

    section "Verifying"
    if sudo sbctl verify 2>/dev/null | grep -qi "$BID/grubx64.efi is signed"; then
        ok "GRUB is signed"
    else
        warn "Could not confirm GRUB signature via sbctl verify."
    fi
fi

if [ "$sb_ok" = yes ]; then
    record "Secure Boot" "OK-UEFI" "Reboot → UEFI → enable Secure Boot"
    ok "sbctl ready. ${B}Enable Secure Boot in your UEFI setup${R} after reboot."
else
    record "Secure Boot" "FAIL" "$GUIDE → Part 3"
    err "Secure Boot setup incomplete — see $GUIDE, Part 3."
fi
