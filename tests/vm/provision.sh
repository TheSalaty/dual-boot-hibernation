#!/usr/bin/env bash
# Runs inside the test VM, once: swap for hibernation, a fake Windows boot
# manager, and firmware entries that look like a real dual-boot machine.
set -euo pipefail

# Hibernation: a swap file; systemd finds the image again by itself on UEFI.
if ! swapon --show | grep -q /swapfile; then
    sudo btrfs filesystem mkswapfile --size 3g /swapfile
    echo '/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab >/dev/null
    sudo swapon /swapfile
fi

# "Windows": a GRUB image at the path of the Windows boot manager. It reports
# on the serial line, waits, and restarts — like someone clicking Restart.
cat >/tmp/fake-windows.cfg <<'CFG'
serial --speed=115200
terminal_output serial
echo "FAKE-WINDOWS started"
sleep 5
echo "FAKE-WINDOWS restarting"
reboot
CFG
sudo mkdir -p /efi/EFI/Microsoft/Boot
sudo grub-mkstandalone -O x86_64-efi -o /efi/EFI/Microsoft/Boot/bootmgfw.efi \
    --modules="serial sleep reboot echo" "boot/grub/grub.cfg=/tmp/fake-windows.cfg"

# Firmware entries: drop the auto-created ones, add Linux and Windows.
for n in $(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\? \(Linux\|Windows Boot Manager\)$/\1/p;s/^Boot\([0-9A-F]\{4\}\)\*\? \(Linux\|Windows Boot Manager\)\t.*/\1/p'); do
    sudo efibootmgr -q -b "$n" -B
done
sudo efibootmgr -q -c -d /dev/vda -p 2 -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'
sudo efibootmgr -q -c -d /dev/vda -p 2 -L "Linux" -l '\EFI\BOOT\BOOTX64.EFI'
efibootmgr

# An SSH login is not a local seat, so logind would refuse to reboot or
# hibernate for it. Allow it for the test user.
pacman -Q polkit >/dev/null 2>&1 || sudo pacman -Sy --noconfirm --needed polkit >/dev/null
sudo tee /etc/polkit-1/rules.d/49-os-switch-test.rules >/dev/null <<'RULE'
polkit.addRule(function (action, subject) {
    if (action.id.indexOf("org.freedesktop.login1.") === 0 && subject.user === "arch")
        return polkit.Result.YES;
});
RULE
