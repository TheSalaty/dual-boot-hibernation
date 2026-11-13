# SteamOS and other Arch-based systems

**SteamOS is untested.** Nobody working on this project owns a Steam Deck. The
design avoids the known obstacles, but no part of it has run on SteamOS. If you
try it, please open an issue with the output of `os-switch status`.

## What should carry over

- `os-switch` is a single program without dependencies. Nothing has to be
  installed through `pacman`, which SteamOS undoes with every update.
- Windows is selected through firmware boot entries, independent of the boot
  loader.
- The units live in `/etc/systemd/system`, not under `/usr`.

## Known limits on SteamOS

- **Hibernation is not set up by Valve.** The swap file is small and the kernel
  has no resume settings. `os-switch reboot-windows` works without hibernation;
  `os-switch windows` needs you to set hibernation up yourself, and an update may
  undo it. `install.sh` does not attempt it there.
- **No GNOME.** The power-menu extension does not apply. Add
  `os-switch reboot-windows` as a non-Steam shortcut or a desktop entry.
- **`/usr/local` and `/etc`** are expected to survive updates, but this is
  unverified. If `os-switch status` reports missing pieces after an update,
  re-run `install.sh`.
- **One internal disk.** The planned WSL integration ([wsl.md](wsl.md)) needs
  Linux on a disk of its own and will not work on a single-disk device.
- `zenity` or `kdialog` is only used for questions; without either, the command
  asks on the terminal and refuses anything destructive when there is none.

## Other Arch-based systems

| You have                         | What changes                                                              |
| -------------------------------- | ------------------------------------------------------------------------- |
| Another desktop (KDE, niri, …)   | No extension; bind the `os-switch` commands yourself                      |
| Another boot loader              | `install.sh` skips the hibernation and Secure Boot modules; `os-switch` works |
| Firmware that ignores `BootNext` | Use the GRUB fallback (`backend = grub`), GRUB only                       |
| A board whose clock cannot switch it on        | `after_freeze = reboot`, or `poweroff` and the power button |
| ext4 instead of Btrfs            | Simpler swap file, see the setup guide                                    |
