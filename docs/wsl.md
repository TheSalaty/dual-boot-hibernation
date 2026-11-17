# Linux inside Windows through WSL

Windows is only there for the games that don't run on Linux. Everything else
comes from the Linux installation, also while Windows is running, without
installing anything twice: Windows hands the Linux disks to WSL, your real Linux
starts there with its own services, and its programs appear in the Start menu.

**Status: experimental.** It runs end to end in a test setup (Windows 11 in a
virtual machine with WSL, and the disk of a Linux test machine). What that
setup cannot show is listed under [Not verified](#not-verified).

## What works

| You restarted into Windows with    | Linux in Windows                                          |
| ---------------------------------- | --------------------------------------------------------- |
| **Restart → Windows**              | Starts at sign-in. Programs in the Start menu, files editable, services running, packages installable. |
| **Hibernate → Windows**            | Starts at sign-in, **view only**. Programs in the Start menu, files readable, nothing on the disks changes. |

**Frozen means read-only.** While a frozen session exists, nothing may write to
the Linux filesystems: the session wakes up with its old view of them, and any
change made in between corrupts them. So in that case:

- The Linux disks are write-blocked as devices, and mounted read-only without
  replaying a journal. Not one byte changes.
- Your files can be opened but not saved: Documents, projects, data disks.
- Programs still start, because what they write themselves (settings, caches,
  everything hidden in the home folder) goes to a layer in memory. It is thrown
  away when Windows shuts down or you go back to Linux.
- Services and timers of the installation do not run. A sync client or a backup
  must not run a second time on old data.

What follows from the throwaway layer: a new file saved directly in the home
folder (not in a subfolder) is lost too, and a program that renews a login
while it runs view only may ask you to sign in again in Linux.

In Windows you get:

- **Linux programs in the Start menu**, in a folder *Linux*, named like
  *Firefox (Linux)*, with their own icons. They open as normal windows.
- **Back to Linux** in the Start menu, in the notification area, and optionally
  on the desktop: closes Linux properly, then restarts the machine.
- **A notification-area icon** that shows whether Linux is running, and
  whether it is view only.
- **Images copied in Windows** can be pasted into Linux programs (needs
  `wl-clipboard` installed in Linux).

The Start menu entries are shortcuts, created from the `.desktop` files of the
Linux installation. They are brought up to date at every sign-in and within a
minute after a program was installed or removed in Linux while Windows runs.

## Requirements

- Linux on disks of its own. `wsl --mount` hands over whole disks and cannot
  hand over the one Windows starts from: see
  [windows-install.md](windows-install.md).
- WSL 2 on Windows 11: `wsl --install --no-distribution` in an administrator
  prompt, then restart. You don't need a Linux distribution from the Store.
- A Linux installation with systemd (any current distribution), root on Btrfs
  or ext4.

## Install

Copy the `windows` folder of this repository to Windows, then in an
administrator PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\os-switch.ps1 install -DesktopShortcut
```

It finds the disks with Linux partitions, shows them, downloads a 3 MB helper
system (Alpine Linux, checked against its checksum), and registers a task that
runs at sign-in. Leave out `-DesktopShortcut` if you don't want *Back to Linux*
on the desktop.

To update, download the folder again and run the same command: it stops the
running Linux (close its programs first) and starts it with the new files.

```powershell
.\windows\os-switch.ps1 status      # what is set up and running
.\windows\os-switch.ps1 start-menu  # after installing programs in Linux
.\windows\os-switch.ps1 detach      # stop Linux, give the disks back
.\windows\os-switch.ps1 uninstall   # remove everything; Linux is not changed
```

## How it works

```text
sign-in
  a task with administrator rights runs os-switch.ps1 attach
    wsl --mount --bare <each Linux disk>         disks appear inside WSL, unmounted
    helper system: os-switch-wsl start
      write-block the disks
      find the Linux root, mount it read-only without journal replay
      hibernation image in a swap area?
        no:  unblock, mount root and the fstab entries read-write,
             start Linux's own systemd in a container  (hardware units masked)
        yes: keep the block, mount everything read-only, put a layer in memory
             on top, start systemd with only what programs need
    create the Start menu entries from the .desktop files
    stay in the notification area
```

- **The helper system** is a tiny WSL distribution that only contains
  `os-switch-wsl`. WSL needs a distribution to run anything; your Linux stays
  what it is and is not converted or copied.
- **The container** has its own process and mount namespaces and runs the
  systemd of your installation, so services such as Docker work. It shares the
  network of WSL. Units that need real hardware are masked for that start only
  (display manager, NetworkManager, Bluetooth, udev, clock sync, power
  management, the os-switch units); nothing is changed on disk for it.
- **fstab** entries are mounted by `os-switch-wsl`, because systemd ignores
  device entries in a container. Only disks that Windows handed over are used.
  An entry that cannot be mounted is skipped.
- **Programs** run as services of your user's systemd, with the display, sound
  and GPU libraries of WSLg.
- **View only** uses overlayfs: the real root below, memory on top. The home
  folder gets a layer of its own, and every entry in it that is not hidden is
  put back on top read-only. If the swap area cannot be found, Linux counts as
  hibernated.
- **Images on the clipboard**: WSL offers an image copied in Windows to Linux
  programs as BMP only, which most of them do not paste. The notification-area
  process saves it as PNG and `wl-copy` offers that. The Windows clipboard is
  not changed by it.
- **Back to Linux** shuts the container down, unmounts, detaches the disks and
  restarts. A plain Windows restart skips that: for Linux it is like pulling the
  plug. Btrfs and ext4 survive it, running programs lose unsaved work.

## Not verified

- **On more than one real machine.** Restart mode runs on one (Manjaro on two
  Btrfs disks); view-only mode ran in virtual machines only.
- **Graphics acceleration in programs.** Linux programs draw with the graphics
  card of Windows when `eglinfo` (package `mesa-utils`) is installed in Linux
  and reports WSL's driver as working; otherwise in software. The driver
  answered on one machine with an Nvidia card; how programs behave with it is
  not tested.
- **Games' anti-cheat with WSL enabled.** Riot Vanguard accepted it on one
  machine; that can change with any update.

## Planned

- `sticky = yes`: Windows restarts, including the ones Windows Update triggers,
  stay in Windows until *Back to Linux*.
- Setup that stops Windows Update from restarting the machine while you are
  signed in.

## Testing

`tests/vm/windows/` builds the test setup: `winvm.sh` installs Windows 11
(90-day evaluation) unattended in QEMU, `run.sh` runs the scenario above
against the Linux test machine of `tests/vm/`, including a byte-for-byte
comparison of the Linux disk around a view-only session that Windows ends
without stopping Linux.
