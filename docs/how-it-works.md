# How the handoff works

`os-switch` is one small program. Run as you, it drives the handoff; the few
steps that need root go through `os-switch helper …`, the only thing the sudo
rule allows.

## Commands

| Command                    | What it does                                                    |
| -------------------------- | --------------------------------------------------------------- |
| `os-switch windows`        | Freeze the Linux session to disk, start Windows                 |
| `os-switch reboot-windows` | Shut Linux down, start Windows                                  |
| `os-switch hibernate`      | Freeze the Linux session and power off                          |
| `os-switch status`         | Check boot entries, hibernation, helper, units; say what's missing |

The GNOME extension only calls these. On another desktop, bind them to a key or
a menu entry.

## What `os-switch windows` does

```text
os-switch windows
  check: helper usable, Windows boot entry present, hibernation available
  unmount drives Windows can write to (NTFS, exFAT, FAT; not the EFI partition)
    busy -> ask: close the programs using it, or cancel
  select Windows for the next start
  freeze the session, power off, the clock switches the machine back on
    (or restart directly, see after_freeze)
    ... Windows runs ...
  Linux wakes up
  make Linux the default again, mount the drives again
```

If any step fails, everything done so far is undone and Linux keeps running.

Two systemd units repeat the last line independently of the command, so a
handoff can never leave the machine pointing at Windows:

- `os-switch-resume.service` runs after every wake-up from hibernation.
- `os-switch-boot.service` runs on every cold start, for the case where the
  frozen session was discarded instead of resumed.

## Selecting Windows

**Firmware boot entries (default).** `os-switch` asks the firmware to start the
Windows entry once (`BootNext`). It finds that entry by what it loads
(`bootmgfw.efi`), not by a menu title. This works with any boot loader, and it
is the same mechanism as your mainboard's boot menu.

Version 1 used `grub-reboot` with the GRUB menu title. That title contains a
device name such as `nvme1n1p1`, which changes when the drives are enumerated in
a different order, and GRUB cannot clear the one-time flag when `/boot` is on
Btrfs. Both made the switch unreliable.

**GRUB fallback (`backend = grub`).** Some firmware ignores `BootNext`. For
those, `install.sh` can add a GRUB snippet that reads a flag from a small
environment file on the EFI partition (FAT, so GRUB can write it), clears it,
and then starts the Windows boot manager.

**Sticky (`sticky = yes`).** Instead of a one-time start, Windows becomes the
first boot entry until Linux runs again. Windows restarts, including the ones
Windows Update triggers, then stay in Windows. This needs the Windows companion
to get back ("Back to Linux"), which is not built yet, so it is off by default.
Without the companion you would return through the firmware boot menu.

## After freezing

Set `after_freeze` in `/etc/os-switch.conf`:

- `rtc` (default): power off the regular way and let the real-time clock
  switch the machine back on. The wake-up time is estimated from the size of
  the image. If the clock fires before the machine is off, the kernel cancels
  the hibernation; `os-switch` then allows more time, tries again and
  remembers the value.
- `reboot`: restart straight after writing the image (systemd's
  `HibernateMode=reboot`, set for this one handoff). A few seconds faster. The
  kernel documentation warns that this mode skips steps and fails on some
  machines; with the proprietary Nvidia driver it hung with a black screen,
  and a session frozen that way did not wake up again.
- `poweroff`: power off and press the button yourself.

## Drives

A frozen Linux that still has a drive mounted wakes up with an outdated view of
it. If Windows wrote to that drive in between, the drive is corrupted. So every
mounted drive that Windows can write to is unmounted before freezing and mounted
again after waking.

Btrfs and ext4 drives stay mounted: Windows has no driver that writes to them.

## The root helper

`/etc/sudoers.d/os-switch` allows `os-switch helper *` without a password. The
helper accepts a fixed list of actions: select or deselect Windows, set the
hibernate mode, unmount a drive, close the programs using a drive, mount the
drives from `fstab`. It checks every argument: a drive, for example, must be a
currently mounted Windows-writable drive. It never takes a command or a boot
target from the caller.

## Files

| Path                                   | Purpose                                 |
| -------------------------------------- | --------------------------------------- |
| `/usr/local/bin/os-switch`             | the program                             |
| `/etc/os-switch.conf`                  | settings                                |
| `/etc/sudoers.d/os-switch`             | sudo rule for the helper                |
| `/etc/systemd/system/os-switch-*.service` | units around hibernation and boot    |
| `/var/lib/os-switch/boot-order`        | saved boot order during a sticky trip   |
| `/etc/systemd/sleep.conf.d/90-os-switch.conf` | exists only during a handoff     |
