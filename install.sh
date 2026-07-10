#!/usr/bin/env bash
#
# install.sh — Linux ⇄ Windows Dual-Boot: Hibernate Handoff + Secure Boot + GNOME
#
# Interactive, self-contained installer for the setup described in
# dual-boot-hibernate-secureboot-gnome.md. It detects your system, asks which
# modules you want, does the work, validates each step, and prints a report
# telling you exactly where to continue in the manual guide if anything fails.
#
# Run it as your normal user (NOT root); it uses sudo where needed.
#   chmod +x install.sh && ./install.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE="README.md"
EXT_UUID="hibernate-windows@salaty"
SCRIPT_PATH="$HOME/.local/bin/hibernate-windows.sh"
HANDOFF_SRC="$HERE/scripts/hibernate-windows.sh"

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
banner "Dual-Boot Hibernate / Secure Boot / GNOME — Installer"

if [ "$(id -u)" -eq 0 ]; then
    err "Please run as your normal user, not root (the script uses sudo itself)."
    exit 1
fi
if ! command -v pacman >/dev/null; then
    err "This installer automates the Arch/Manjaro setup and needs pacman, which"
    err "was not found — your distribution isn't supported by the automated path."
    info "The concepts (swapfile resume, grub-reboot one-shot, sbctl, NTFS mounts)"
    info "apply to any distro — follow the manual guide in $GUIDE."
    exit 1
fi

# Core tools the installer relies on across modules.
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
SESSION="${XDG_SESSION_TYPE:-unknown}"

info "UEFI firmware .......... $UEFI"
info "Root filesystem ........ ${ROOT_FS:-unknown}"
info "RAM .................... ${RAM_GB} GB (${RAM_MIB} MiB)"
info "Bootloader is GRUB ..... $HAS_GRUB"
info "GNOME desktop .......... $IS_GNOME (session: $SESSION)"

if [ "$HAS_GRUB" != yes ]; then
    err "GRUB not detected. This installer only supports GRUB. Aborting."
    exit 1
fi

echo
warn "This will modify /etc/default/grub, /etc/fstab, /etc/mkinitcpio.conf and"
warn "reinstall GRUB / rebuild the initramfs. Backups (*.bak.TIMESTAMP) are made."
ask_yn "Continue?" y || { echo "Aborted."; exit 0; }

STAMP=$(date +%Y%m%d-%H%M%S)
backup() { [ -f "$1" ] && sudo cp -a "$1" "$1.bak.$STAMP" && info "backup: $1.bak.$STAMP"; }

sudo -v || { err "sudo authentication failed."; exit 1; }

# Keep the sudo timestamp warm so the long swapfile write never stalls waiting
# for a password prompt mid-run. Stops itself when this script exits.
( while true; do sudo -n true 2>/dev/null; sleep 45; kill -0 "$$" 2>/dev/null || exit 0; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# ---------------------------------------------------------------------------
# Choose modules
# ---------------------------------------------------------------------------
section "Choose what to install"

DO_HIBERNATE=no; ask_yn "Set up hibernation (swapfile + resume config)?" y && DO_HIBERNATE=yes

DO_SB=no
if [ "$UEFI" = yes ]; then
    SB_STATE="unknown"
    command -v sbctl >/dev/null && SB_STATE=$(sbctl status 2>/dev/null | awk -F'\t' '/Secure Boot/{print $NF}')
    MOK_STATE=$(mokutil --sb-state 2>/dev/null || true)
    info "Current Secure Boot: ${SB_STATE:-unknown} ${MOK_STATE:+($MOK_STATE)}"
    if echo "$MOK_STATE $SB_STATE" | grep -qiE 'enabled'; then
        info "Secure Boot already appears enabled — you may not need this module."
        ask_yn "Set up Secure Boot with your own keys (sbctl) anyway?" n && DO_SB=yes
    else
        info "Your firmware supports Secure Boot and it's currently off."
        ask_yn "Set up Secure Boot with your own keys (sbctl)?" y && DO_SB=yes
    fi
else
    info "No UEFI firmware detected → Secure Boot is not applicable, skipping."
fi

DO_MOUNT=no
mapfile -t NTFS_AVAIL < <(lsblk -rno NAME,FSTYPE,UUID,LABEL 2>/dev/null | awk '$2=="ntfs"||$2=="ntfs3"{print}')
if [ "${#NTFS_AVAIL[@]}" -gt 0 ]; then
    ask_yn "Auto-mount Windows/NTFS data drives at boot (great for Steam)?" y && DO_MOUNT=yes
else
    info "No NTFS partitions found → skipping auto-mount question."
fi

DO_SCRIPT=no; ask_yn "Install the 'Hibernate → Windows' handoff script?" y && DO_SCRIPT=yes
DO_HOOK=no;   ask_yn "Auto-remount the shared drives after resume (recommended if you mount them)?" y && DO_HOOK=yes
DO_EXT=no
if [ "$IS_GNOME" = yes ]; then
    ask_yn "Install the GNOME power-menu extension (two entries + settings)?" y && DO_EXT=yes
else
    info "GNOME not detected → skipping the extension."
fi

# ===========================================================================
# MODULE 1 — Hibernation
# ===========================================================================
if [ "$DO_HIBERNATE" = yes ]; then
    banner "Module 1/6 — Hibernation (swapfile + resume)"
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
fi

# ===========================================================================
# MODULE 2 — Secure Boot (sbctl)
# ===========================================================================
if [ "$DO_SB" = yes ]; then
    banner "Module 2/6 — Secure Boot with your own keys (sbctl)"
    sb_ok=yes
    step "Ensuring sbctl is installed…"
    sudo pacman -S --needed --noconfirm sbctl >/dev/null 2>&1 || { err "could not install sbctl"; sb_ok=no; }

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
fi

# ===========================================================================
# MODULE 3 — Auto-mount NTFS drives
# ===========================================================================
declare -a NTFS_MOUNTS
# seed from existing fstab ntfs entries
mapfile -t NTFS_MOUNTS < <(awk '/ntfs/ && $2 ~ /^\/mnt\// {print $2}' /etc/fstab 2>/dev/null)

if [ "$DO_MOUNT" = yes ]; then
    banner "Module 3/6 — Auto-mount Windows/NTFS drives"
    mnt_ok=yes
    backup /etc/fstab
    for line in "${NTFS_AVAIL[@]}"; do
        name=$(echo "$line" | awk '{print $1}')
        uuid=$(echo "$line" | awk '{print $3}')
        label=$(echo "$line" | cut -d' ' -f4-)
        [ -z "$uuid" ] && { warn "/dev/$name has no UUID, skipping"; continue; }
        if grep -q "$uuid" /etc/fstab; then info "/dev/$name already in fstab — skipping"; continue; fi
        safe=$(echo "${label:-$name}" | tr ' /' '__' | tr -cd '[:alnum:]_-')
        mp="/mnt/win_${safe:-$name}"
        if ask_yn "Add /dev/$name (${label:-no label}) → $mp ?" y; then
            sudo mkdir -p "$mp"
            echo "UUID=$uuid $mp ntfs-3g uid=$(id -u),gid=$(id -g),rw,user,exec,umask=000,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
            NTFS_MOUNTS+=("$mp")
            ok "added $mp"
        fi
    done
    step "systemctl daemon-reload && mount -a…"
    sudo systemctl daemon-reload
    if sudo mount -a 2>/dev/null; then ok "drives mounted"; else warn "mount -a reported issues (check with: findmnt --verify)"; mnt_ok=no; fi
    # de-dup mount list
    mapfile -t NTFS_MOUNTS < <(printf '%s\n' "${NTFS_MOUNTS[@]}" | awk 'NF' | sort -u)
    [ "$mnt_ok" = yes ] && record "Auto-mount NTFS" "OK" "" || record "Auto-mount NTFS" "WARN" "$GUIDE → Part 5.3"
fi

# ===========================================================================
# MODULE 4 — Hibernate → Windows script + sudoers
# ===========================================================================
if [ "$DO_SCRIPT" = yes ]; then
    banner "Module 4/6 — 'Hibernate → Windows' script"
    scr_ok=yes
    step "Installing dependencies (zenity lsof psmisc libnotify)…"
    sudo pacman -S --needed --noconfirm zenity lsof psmisc libnotify >/dev/null 2>&1 || warn "some deps may be missing"

    # detect Windows GRUB entry
    WIN_ENTRY=$(sudo grep -i "menuentry '" /boot/grub/grub.cfg 2>/dev/null | cut -d"'" -f2 | grep -i windows | head -1)
    if [ -n "$WIN_ENTRY" ]; then
        ok "detected Windows entry: $WIN_ENTRY"
    else
        WIN_ENTRY="Windows Boot Manager"
        warn "No Windows GRUB entry found (os-prober off?). Placeholder set — edit the config later."
        scr_ok=no
    fi

    # grub-reboot's one-shot boot is only honoured when grub.cfg was generated
    # with GRUB_DEFAULT=saved. Without this the handoff silently does nothing.
    section "GRUB one-shot boot support (GRUB_DEFAULT=saved)"
    backup /etc/default/grub
    if grep -qE '^\s*GRUB_DEFAULT=saved\b' /etc/default/grub; then
        ok "GRUB_DEFAULT=saved already set"
    else
        if grep -qE '^\s*GRUB_DEFAULT=' /etc/default/grub; then
            sudo sed -i -E 's|^\s*GRUB_DEFAULT=.*$|GRUB_DEFAULT=saved|' /etc/default/grub
        else
            echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
        fi
        step "Regenerating grub.cfg…"
        if sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then
            ok "GRUB_DEFAULT=saved applied"
        else
            err "grub-mkconfig failed — grub-reboot may not work"; scr_ok=no
        fi
    fi
    if grep -qE '^\s*GRUB_SAVEDEFAULT=true' /etc/default/grub; then
        warn "GRUB_SAVEDEFAULT=true is set — it makes the last-booted OS sticky."
        warn "For a one-shot handoff that reverts to Linux, set it to false."
    fi

    # Install the handoff script verbatim from the repo and write its config, so
    # there is a single source of truth (no generated copy to drift).
    section "Installing the handoff script"
    if [ -r "$HANDOFF_SRC" ]; then
        mkdir -p "$(dirname "$SCRIPT_PATH")"
        install -m 0755 "$HANDOFF_SRC" "$SCRIPT_PATH"
        ok "installed $SCRIPT_PATH"

        CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
        mkdir -p "$CONF_DIR"
        drives_literal=""; for m in "${NTFS_MOUNTS[@]}"; do drives_literal+=$(printf ' %q' "$m"); done
        {
            printf '# Auto-generated by install.sh — edit and re-run, or tweak in place.\n'
            printf 'WIN_ENTRY=%q\n' "$WIN_ENTRY"
            printf 'DRIVES=(%s )\n' "$drives_literal"
        } > "$CONF_DIR/hibernate-windows.conf"
        ok "wrote config: $CONF_DIR/hibernate-windows.conf"
    else
        err "Handoff script not found at $HANDOFF_SRC — run from the repo checkout."
        scr_ok=no
    fi

    section "Passwordless sudo for the handoff commands"
    SUDOERS_CMDS=""
    for c in grub-reboot grub-editenv umount fuser; do
        p=$(command -v "$c" 2>/dev/null)
        [ -n "$p" ] && SUDOERS_CMDS="${SUDOERS_CMDS:+$SUDOERS_CMDS, }$p"
    done
    if [ -z "$SUDOERS_CMDS" ]; then
        warn "Could not resolve any handoff command paths — skipping the sudoers rule."
        scr_ok=no
    else
        echo "$USER ALL=(root) NOPASSWD: $SUDOERS_CMDS" | sudo tee /etc/sudoers.d/hibernate-windows >/dev/null
        sudo chmod 440 /etc/sudoers.d/hibernate-windows
        if sudo visudo -c >/dev/null 2>&1; then ok "sudoers rule valid"; else err "sudoers invalid — removing"; sudo rm -f /etc/sudoers.d/hibernate-windows; scr_ok=no; fi
    fi

    [ "$scr_ok" = yes ] && record "Handoff script" "OK" "" || record "Handoff script" "WARN" "$GUIDE → Part 4.2 & 5 (set WIN_ENTRY)"
fi

# ===========================================================================
# MODULE 5 — Resume remount hook
# ===========================================================================
if [ "$DO_HOOK" = yes ]; then
    banner "Module 5/6 — Auto-remount drives on resume"
    if [ "${#NTFS_MOUNTS[@]}" -eq 0 ]; then
        warn "No NTFS mountpoints known — nothing to remount. Skipping."
        record "Resume remount hook" "SKIP" "no drives configured"
    else
        drives_str="${NTFS_MOUNTS[*]}"
        sudo tee /usr/lib/systemd/system-sleep/remount-steam-drives >/dev/null <<EOF
#!/bin/sh
# Auto-generated by install.sh — remount shared drives after resume.
DRIVES="$drives_str"
case "\$1" in
  post)
    for m in \$DRIVES; do
      mountpoint -q "\$m" || mount "\$m" 2>/dev/null
    done
    ;;
esac
EOF
        sudo chmod +x /usr/lib/systemd/system-sleep/remount-steam-drives
        if [ -x /usr/lib/systemd/system-sleep/remount-steam-drives ]; then
            ok "installed remount hook for: $drives_str"
            record "Resume remount hook" "OK" ""
        else
            err "hook not executable"
            record "Resume remount hook" "FAIL" "$GUIDE → Part 7"
        fi
    fi
fi

# ===========================================================================
# MODULE 6 — GNOME extension
# ===========================================================================
if [ "$DO_EXT" = yes ]; then
    banner "Module 6/6 — GNOME power-menu extension"
    ext_ok=yes
    EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
    DIST_DIR="$HERE/gnome-extension/dist/$EXT_UUID"

    # Find a packaged release zip shipped next to the installer, if any.
    EXT_ZIP=""
    for z in "$HERE"/*.shell-extension.zip; do [ -e "$z" ] && { EXT_ZIP="$z"; break; }; done

    # Copy a fully built extension directory into place and compile its schema.
    install_ext_from_dir() {
        rm -rf "$EXT_DIR"
        mkdir -p "$EXT_DIR"
        cp -a "$1"/. "$EXT_DIR"/
        [ -d "$EXT_DIR/schemas" ] && glib-compile-schemas "$EXT_DIR/schemas" >/dev/null 2>&1 || true
    }

    if [ -n "$EXT_ZIP" ] && command -v gnome-extensions >/dev/null; then
        step "Installing packaged extension ($(basename "$EXT_ZIP"))…"
        gnome-extensions install --force "$EXT_ZIP" >/dev/null 2>&1 \
            && ok "installed from zip" || { err "gnome-extensions install failed"; ext_ok=no; }
    elif [ -d "$DIST_DIR" ]; then
        step "Installing pre-built extension from gnome-extension/dist/…"
        install_ext_from_dir "$DIST_DIR"; ok "installed from dist"
    elif command -v npm >/dev/null; then
        step "Building the extension from source (npm ci && npm run build)…"
        if ( cd "$HERE" && npm ci >/dev/null 2>&1 && npm run build >/dev/null 2>&1 ) && [ -d "$DIST_DIR" ]; then
            install_ext_from_dir "$DIST_DIR"; ok "built and installed"
        else
            err "npm build failed"; ext_ok=no
        fi
    else
        warn "No release zip, no gnome-extension/dist/, and npm is not installed."
        warn "Build it with 'npm run pack' (needs Node) or download the release zip,"
        warn "then re-run — the rest of the setup is unaffected."
        ext_ok=skip
    fi

    if [ "$ext_ok" = yes ]; then
        ok "Extension installed."
        record "GNOME extension" "OK-RELOGIN" "Log out/in, then: gnome-extensions enable $EXT_UUID"
    elif [ "$ext_ok" = skip ]; then
        record "GNOME extension" "SKIP" "build/pack the extension (npm run pack), then re-run"
    else
        record "GNOME extension" "FAIL" "$GUIDE → Part 6"
    fi
fi

# ===========================================================================
# Final report
# ===========================================================================
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
[ "$DO_HIBERNATE" = yes ] && info "1. ${B}Reboot${R} — required for hibernation (new initramfs + kernel cmdline)."
[ "$DO_SB" = yes ]        && info "2. After reboot: enter UEFI and turn ${B}Secure Boot = Enabled${R}."
[ "$DO_EXT" = yes ]       && info "3. Log out & back in, then: ${B}gnome-extensions enable $EXT_UUID${R}"
info "Full manual guide: ${B}$GUIDE${R}"

printf '\n'
if [ "$FAILS" -gt 0 ]; then
    err "Finished with $FAILS failed module(s). See the ↳ pointers above for where to continue."
    exit 1
elif [ "$MANUAL" -gt 0 ]; then
    ok "All selected modules installed. A few manual steps remain (see above). 🏔️"
else
    ok "All done! 🎉"
fi
