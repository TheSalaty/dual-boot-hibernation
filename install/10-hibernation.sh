#!/usr/bin/env bash
# Module: hibernation (swap file + kernel resume settings). Sourced by install.sh.
# shellcheck disable=SC2154  # variables come from install.sh

banner "Hibernation (swapfile + resume)"
hib_ok=yes

# -- swapfile --
NEED_SWAP=yes
if swapon --show=size --noheadings --bytes 2>/dev/null | awk '{s+=$1} END{exit !(s>=0.95*'"$RAM_KB"'*1024)}'; then
    info "Active swap already ≥ RAM."
    ask_yn "Recreate /swapfile anyway?" n || NEED_SWAP=no
fi

if [ "$NEED_SWAP" = yes ]; then
    section "Creating ${RAM_GB} GB swapfile"
    # Refuse to fill the root filesystem: need the swapfile + a little slack.
    AVAIL_MIB=$(df --output=avail -m / 2>/dev/null | awk 'NR==2{print $1}')
    if [ -n "$AVAIL_MIB" ] && [ "$AVAIL_MIB" -lt $((RAM_MIB + 512)) ]; then
        err "Only ${AVAIL_MIB} MiB free on / — need ≥ $((RAM_MIB + 512)) MiB for the swapfile."
        hib_ok=no
    else
        sudo swapoff /swapfile 2>/dev/null || true
        sudo rm -f /swapfile
        if [ "$ROOT_FS" = btrfs ]; then
            step "Btrfs: NoCOW swapfile"
            sudo truncate -s 0 /swapfile
            sudo chattr +C /swapfile
        fi
        step "Writing ${RAM_MIB} MiB (this can take a moment)…"
        if sudo dd if=/dev/zero of=/swapfile bs=1M count="$RAM_MIB" status=progress 2>/dev/null; then
            sudo chmod 600 /swapfile
            sudo mkswap /swapfile >/dev/null
            if sudo swapon /swapfile; then ok "swapfile active"; else err "swapon failed"; hib_ok=no; fi
        else
            err "Could not write swapfile."; hib_ok=no
        fi
        if [ "$ROOT_FS" = btrfs ] && [ "$hib_ok" = yes ]; then
            sudo lsattr /swapfile 2>/dev/null | grep -q 'C' && ok "NoCOW flag set" || warn "NoCOW flag missing"
        fi
    fi
fi

# -- fstab entry --
if [ "$hib_ok" = yes ] && ! grep -qE '^\s*/swapfile\s' /etc/fstab; then
    backup /etc/fstab
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    ok "added /swapfile to /etc/fstab"
fi

# -- resume params --
if [ "$hib_ok" = yes ]; then
    section "Kernel resume configuration"
    RUUID=""; ROFF=""; ADD=""
    if [ -f /swapfile ]; then
        # Swapfile: resume needs the filesystem UUID *and* the file offset.
        RUUID=$(findmnt -no UUID -T /swapfile 2>/dev/null)
        if [ "$ROOT_FS" = btrfs ]; then
            ROFF=$(sudo btrfs inspect-internal map-swapfile -r /swapfile 2>/dev/null)
        else
            ROFF=$(sudo filefrag -v /swapfile 2>/dev/null | awk '$1=="0:"{gsub(/\.\./,"",$4); print $4; exit}')
        fi
        [ -n "$RUUID" ] && [ -n "$ROFF" ] && ADD="resume=UUID=$RUUID resume_offset=$ROFF"
    else
        # Swap lives on a partition (kept existing swap): UUID only, no offset.
        SWAPDEV=$(swapon --show=name --noheadings 2>/dev/null | grep '^/dev/' | head -1)
        [ -n "$SWAPDEV" ] && RUUID=$(blkid -s UUID -o value "$SWAPDEV" 2>/dev/null)
        [ -n "$RUUID" ] && ADD="resume=UUID=$RUUID"
    fi
    info "kernel resume: ${ADD:-<undetermined>}"

    if [ -z "$ADD" ]; then
        err "Could not determine the resume device — hibernation won't resume."; hib_ok=no
    else
        backup /etc/default/grub
        if grep -q 'resume=' /etc/default/grub; then
            warn "resume= already present in /etc/default/grub — leaving it untouched."
        else
            sudo sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=.)(.*)(.)\$|\1\2 $ADD\3|" /etc/default/grub
            grep -q "resume=UUID=$RUUID" /etc/default/grub && ok "added resume params to GRUB cmdline" \
                || { err "failed to edit GRUB cmdline"; hib_ok=no; }
        fi

        # -- mkinitcpio resume hook --
        backup /etc/mkinitcpio.conf
        if grep -qE '^HOOKS=.*\bresume\b' /etc/mkinitcpio.conf; then
            ok "resume hook already present"
        elif grep -qE '^HOOKS=.*\bfilesystems\b' /etc/mkinitcpio.conf; then
            sudo sed -i -E 's/^(HOOKS=.*\bfilesystems\b)(.*)$/\1 resume\2/' /etc/mkinitcpio.conf
            grep -qE '^HOOKS=.*\bresume\b' /etc/mkinitcpio.conf && ok "added resume hook" \
                || { err "failed to add resume hook"; hib_ok=no; }
        else
            err "No 'filesystems' hook found in mkinitcpio.conf — add 'resume' manually."; hib_ok=no
        fi
    fi
fi

# -- apply --
if [ "$hib_ok" = yes ]; then
    section "Applying (update-grub + mkinitcpio)"
    step "grub-mkconfig…"
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 && ok "grub.cfg regenerated" || { err "grub-mkconfig failed"; hib_ok=no; }
    step "mkinitcpio -P…"
    sudo mkinitcpio -P >/dev/null 2>&1 && ok "initramfs rebuilt" || { err "mkinitcpio failed"; hib_ok=no; }
fi

if [ "$hib_ok" = yes ]; then
    record "Hibernation" "OK-REBOOT" "Reboot required, then test: systemctl hibernate"
    ok "Hibernation configured. ${B}Reboot needed${R} before it works."
else
    record "Hibernation" "FAIL" "$GUIDE → Part 1 & 2"
    err "Hibernation setup incomplete — see $GUIDE, Parts 1 & 2."
fi
