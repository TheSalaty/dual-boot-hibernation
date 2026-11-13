#!/usr/bin/env bash
# Module: mount Windows/NTFS data drives at boot. Sourced by install.sh.
# shellcheck disable=SC2154  # variables come from install.sh

banner "Auto-mount Windows/NTFS drives"
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
        ok "added $mp"
    fi
done
step "systemctl daemon-reload && mount -a…"
sudo systemctl daemon-reload
if sudo mount -a 2>/dev/null; then ok "drives mounted"; else warn "mount -a reported issues (check with: findmnt --verify)"; mnt_ok=no; fi
[ "$mnt_ok" = yes ] && record "Auto-mount NTFS" "OK" "" || record "Auto-mount NTFS" "WARN" "$GUIDE → Part 4"
