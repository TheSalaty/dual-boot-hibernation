# Linux ⇄ Windows dual boot: one-click hibernate handoff

Freeze your Linux session, jump straight into Windows, and come back to your
exact desktop later.

For people who daily-drive Linux but keep Windows for the few games that don't
run there: League of Legends, Valorant and other titles with kernel-level
anti-cheat. Linux stays your real desktop. You freeze it, play, and return to
everything where you left it.

> **Version 2** rewrote the core as `os-switch`. Using Linux from inside
> Windows ([docs/wsl.md](docs/wsl.md)) is experimental: it is in daily use on
> the author's machine and tested in virtual machines, nowhere else yet.

## What you get

| You click               | What happens                                                        |
| ----------------------- | ------------------------------------------------------------------- |
| **Hibernate → Windows** | Linux freezes to disk and the machine restarts straight into Windows |
| **Restart → Windows**   | Linux shuts down and the machine starts Windows                      |
| Windows **Restart**     | Back in Linux, with the frozen session restored                      |

Plus:

- `os-switch status` checks the whole chain and says what is missing.
- Shared NTFS drives are unmounted before the handoff and mounted again after
  it, so Windows can't corrupt them under a frozen Linux.
- Optional setup of hibernation (swap file, resume settings) and Secure Boot
  with your own keys (`sbctl`).
- A GNOME power-menu extension with the entries above.
- Experimental: after *Restart → Windows*, your Linux installation runs inside
  Windows through WSL. Its programs are in the Start menu, nothing is installed
  twice ([docs/wsl.md](docs/wsl.md)).
- German, English, Brazilian Portuguese, Spanish and French. Everything except
  German and English is machine-translated; corrections are welcome.

## Requirements

- An Arch-based distribution with UEFI. Written and tested on Manjaro (GNOME 50,
  Wayland, GRUB, Btrfs).
- Windows installed as a second system on the same machine, ideally on a disk
  of its own: [docs/windows-install.md](docs/windows-install.md).
- Other desktops, boot loaders and SteamOS: see
  [docs/steamos.md](docs/steamos.md) for what works and what doesn't.

## Install

```bash
git clone https://github.com/TheSalaty/dual-boot-hibernation.git
cd dual-boot-hibernation
./install.sh          # as your normal user; it uses sudo where needed
```

The installer asks which parts you want, backs up every system file it edits
(`*.bak.<timestamp>`), and ends with a report of what is left to do by hand:
a reboot, the Secure Boot switch in the firmware, logging in again for the
extension.

It needs the `os-switch` program: either from a release archive placed next to
`install.sh`, or built on the spot if Rust (`cargo`) is installed.

Then in Windows, once ([details](docs/setup-guide.md#part-4--windows-settings-and-shared-drives)):

```bat
powercfg /h off
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

## Use

From the GNOME power menu, or from anywhere else:

```bash
os-switch windows          # freeze Linux, start Windows
os-switch reboot-windows   # shut Linux down, start Windows
os-switch hibernate        # freeze Linux, power off
os-switch status           # check the setup
```

Settings live in `/etc/os-switch.conf`.

## Safety

- **Never let Windows write to a drive that a frozen Linux has mounted.**
  `os-switch` unmounts such drives first. Don't mount them by hand in a way that
  bypasses it.
- **Turn off Windows Fast Startup and hibernation** (`powercfg /h off`). They
  leave NTFS drives in a state Linux must not write to.
- Your Linux system partition (Btrfs, ext4) is safe: Windows cannot write to it.
- Snapshots of the subvolume that holds the swap file break hibernation; see the
  [setup guide](docs/setup-guide.md#btrfs-snapshots-will-break-a-swapfile-in-a-snapshotted-subvolume).

## Documentation

- [How the handoff works](docs/how-it-works.md)
- [Installing Windows next to Linux](docs/windows-install.md)
- [Setup guide](docs/setup-guide.md): hibernation, Secure Boot and shared drives by hand
- [Troubleshooting](docs/troubleshooting.md)
- [SteamOS and other systems](docs/steamos.md)
- [Linux inside Windows through WSL](docs/wsl.md) (experimental)

## Development

```text
crates/os-switch/    the core (Rust, no dependencies)
install.sh           guided installer, runs the modules in install/
gnome-extension/     power-menu entries (TypeScript)
windows/             the Windows side: setup script and the helper that runs in WSL
docs/                guides
tests/vm/            end-to-end tests in QEMU: Linux with a fake Windows, and a real Windows 11
```

```bash
cargo test && cargo clippy --all-targets -- -D warnings   # core
npm ci && npm run lint && npm run type-check && npm run pack   # extension
shellcheck -x install.sh install/*.sh                      # installer
```

The handoff itself is tested in a virtual machine, without touching your boot
entries (needs QEMU with KVM and the OVMF firmware, about 2 GB of disk):

```bash
tests/vm/vm.sh create && tests/vm/vm.sh start && tests/vm/vm.sh wait-ssh
tests/vm/vm.sh ssh 'bash -s' < tests/vm/provision.sh   # once
tests/vm/install.sh && tests/vm/run.sh
tests/vm/vm.sh stop
```

The VM cannot show hardware problems: a hang on restart, or a clock that does
not switch the machine on.

Translations are gettext `.po` files in `crates/os-switch/po/` and
`gnome-extension/po/`.

## Credits

The clock wake-up, the GRUB fallback on the EFI partition and several pre-checks
come from [nicolasdesenv's port](https://github.com/nicolasdesenv/dual-boot-hibernation)
to CachyOS, niri and Noctalia.

## License

MIT, no warranty. See [LICENSE](LICENSE).
