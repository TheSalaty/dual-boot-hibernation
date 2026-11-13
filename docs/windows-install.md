# Installing Windows next to Linux

How to add Windows to a machine that already runs Linux, so that `os-switch`
works and the planned WSL integration ([wsl.md](wsl.md)) stays possible. If
Windows is already installed, skip to [Check the result](#check-the-result).

## Where Windows goes

Give Windows a disk of its own if you can. Two things depend on it:

- Windows keeps its start files on an EFI partition. If that partition is on the
  Linux disk, both systems share it, and a Windows reinstall or repair can
  overwrite the Linux boot loader.
- The planned WSL integration attaches the Linux disk to Windows. Windows cannot
  attach the disk it starts from.

Windows on a partition of the Linux disk works with `os-switch`, but not with
the WSL integration.

## Install

1. Start the installer stick in UEFI mode: pick the entry that begins with
   `UEFI:` in the firmware boot menu.
2. Make sure Windows can only see its own disk. The installer may otherwise put
   its start files on an EFI partition it finds on another disk.
   - Tested: unplug the other disks (or switch them off in the firmware, if it
     has such an option) for the installation, and connect them again
     afterwards.
   - Untested alternative: leave the disks connected and create the EFI
     partition on the Windows disk before the installer runs, so that it has one
     to use there.
3. Pick the Pro edition if you have the choice. Stopping Windows Update from
   restarting the machine is a group policy there; on Home it is unverified.
4. Install as usual. Never let Windows format or "initialise" a Linux disk, even
   when it offers to.

## Check the result

Back in Linux (through the firmware boot menu; Windows puts itself first):

```bash
efibootmgr
sudo ls /boot/efi/EFI
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME
```

- The `Windows Boot Manager` entry points to a different partition than your
  Linux entry: the long ID after `HD(1,GPT,` differs.
- `/boot/efi/EFI` has no `Microsoft` folder.
- If the Windows partition shows up as `BitLocker`, see below.

## Afterwards

**Make Linux the default again.** Use the entry numbers `efibootmgr` printed,
Linux first:

```bash
sudo efibootmgr -o 0001,0000
```

**Test the one-time start.** `os-switch` relies on the firmware honouring it:

```bash
sudo efibootmgr -n 0000 && systemctl reboot   # 0000 = the Windows entry
```

Windows should start without the boot menu, and a restart from Windows should
bring Linux back. If Linux starts instead, your firmware ignores one-time
entries: choose the GRUB fallback in `install.sh`.

**Turn off device encryption, or save the recovery key.** Windows 11 often
encrypts the system disk by itself (Settings → Privacy & security → Device
encryption). An encrypted disk can ask for the recovery key after a firmware
update or a Secure Boot change.

**Apply the Windows settings** from the
[setup guide, part 4](setup-guide.md#part-4--windows-settings-and-shared-drives):
hibernation and Fast Startup off, hardware clock in UTC.

**If you want the WSL integration later,** check early that your games accept
it. In an administrator prompt:

```bat
wsl --install --no-distribution
```

Restart, then start the game. Anti-cheat systems such as Riot Vanguard may
refuse to run with the Windows hypervisor that WSL turns on. This is unverified.
You do not need a Linux distribution inside WSL.
