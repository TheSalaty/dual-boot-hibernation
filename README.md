# Linux ⇄ Windows Dual-Boot: One-Click Hibernate Handoff + Secure Boot (Arch / Manjaro, GNOME)

> Freeze your Linux session, jump straight into Windows, and come back to your
> exact desktop later — plus Secure Boot with your own keys, safe shared Steam
> drives, and a native GNOME power-menu button to trigger it all.

This is a complete, reproducible guide for turning a fresh **Arch-based Linux +
Windows** dual-boot into a machine where switching operating systems is a single
click and **your running Linux session survives the trip to Windows and back**.

> **Perfect if you want to daily-drive Linux but a couple of games keep you
> tethered to Windows** — the classic one being **League of Legends** (and other
> kernel-level anti-cheat titles like Valorant/Vanguard, Fortnite, etc.) that
> simply won't run on Linux. Instead of a full reboot dance every time, you keep
> Linux as your real desktop: freeze it, hop into Windows for a few games, then
> come back to everything exactly where you left it. Two clicks, both directions.

**Keywords / topics** (so people looking for this actually find it):
`hibernate` · `suspend-to-disk` · `dual-boot` · `linux-windows-dual-boot` ·
`secure-boot` · `sbctl` · `shim_lock` · `grub` · `grub-reboot` · `reboot-to-windows` ·
`btrfs` · `btrfs-swapfile` · `resume-offset` · `mkinitcpio` · `arch-linux` ·
`manjaro` · `gnome` · `gnome-shell-extension` · `wayland` · `ntfs` · `steam` ·
`fast-startup` · `efibootmgr` · `league-of-legends` · `valorant` · `vanguard` ·
`anti-cheat` · `gaming` · `switch-to-linux` · `linux-gaming`

---

## What you get

Two "chains", so OS switching works in **both directions**:

| Direction | Trigger | Result |
|-----------|---------|--------|
| **Linux → Windows** | Power menu → *Hibernate → Windows* | Linux freezes to disk, next boot goes **once** to Windows |
| **Windows → Linux** | Windows *Restart* | Reboots into Linux automatically (Linux is the default boot entry) |
| **Back to Linux later** | Pick Linux in GRUB | Your frozen session is restored exactly as you left it |

Plus:

- **Secure Boot** enabled with your own keys via `sbctl` (works alongside Windows).
- **Shared NTFS/Steam drives** are unmounted before the handoff to prevent
  filesystem corruption — with a shutdown-style dialog to kill blocking apps or cancel.
- A tiny **GNOME Shell extension** adds *Hibernate* and *Hibernate → Windows*
  entries to the system power menu, with a preferences page to hide default
  entries you don't need.

## Who this is for / assumptions

This guide matches the following setup (adapt paths where noted):

- **Distro:** Arch-based — written/tested on **Manjaro** (GNOME **50**, Wayland).
- **Bootloader:** **GRUB** (UEFI).
- **Root filesystem:** **Btrfs** (the tricky bits are Btrfs-specific and called out).
- **Desktop:** **GNOME** only (the extension is GNOME Shell specific).
- Windows already installed as a second OS on the same machine.

> If your root FS is ext4, the swapfile part is simpler (no `chattr +C`, no
> Btrfs offset tool) — notes inline.

## Installation — two ways

Grab the repo first:

```bash
git clone https://github.com/TheSalaty/dual-boot-hibernation.git
cd dual-boot-hibernation
```

### Option A — Automated (`install.sh`) ⭐ recommended

The bundled **`install.sh`** does everything in this README interactively. It
detects your system, **checks whether you even need Secure Boot**, and asks
whether you want auto-mounting at boot, the resume-remount hook, and the GNOME
extension. It validates each step, makes backups (`*.bak.<timestamp>`) of every
file it edits, and prints a report telling you exactly where to continue if
something fails.

```bash
chmod +x install.sh
./install.sh          # run as your NORMAL user; it uses sudo where needed
```

The script is self-contained — it writes the handoff script, the GNOME
extension, the resume hook and the sudoers rule for you. A few steps are
inherently manual (reboot, flipping the Secure Boot switch in UEFI, logging out
to load the extension); the report spells them out.

### Option B — Manual

Prefer to understand and do each piece yourself? **The rest of this README is the
manual guide** — [Part 1](#part-1--hibernation-swapfile) through
[Part 7](#part-7--auto-remount-shared-drives-on-resume), with a
[troubleshooting](#troubleshooting) table and full file listings in the
[appendix](#appendix--full-file-listings). The ready-made source files live in
this repo under [`scripts/`](scripts/) and
[`gnome-extension/`](gnome-extension/).

> ⚠️ **Read the [safety notes](#safety-notes-read-this) first** — especially if
> you dual-boot with shared NTFS drives.

### The GNOME extension: install a prebuilt zip or build it yourself

The extension is distributed as a self-contained zip, so it can be installed
independently of `install.sh` (it is **not** on extensions.gnome.org).

```bash
# Option 1 — grab the packaged zip from a GitHub release, then:
gnome-extensions install --force hibernate-windows@salaty.shell-extension.zip

# Option 2 — build it from source (needs Node ≥ 20):
npm ci
npm run pack        # lint-free build -> hibernate-windows@salaty.shell-extension.zip
gnome-extensions install --force hibernate-windows@salaty.shell-extension.zip
```

Then **log out and back in** (Wayland can't hot-load a new extension) and enable
it: `gnome-extensions enable hibernate-windows@salaty`.

`install.sh` does this for you: it prefers a release zip sitting next to it, then
a local `gnome-extension/dist/`, then builds from source if `npm` is available.

Developer scripts: `npm run build` (compile + assets), `npm run lint`,
`npm run type-check`, `npm run format:check`, `npm run pack`.

## Repository layout

```text
dual-boot-hibernation/
├── install.sh                                   # Option A: guided installer
├── README.md                                    # this guide (Option B: manual)
├── package.json                                 # build/lint/pack scripts for the extension
├── scripts/
│   ├── hibernate-windows.sh                     # the handoff script (reads ~/.config/hibernate-windows.conf)
│   ├── copy-assets.mjs                          # build: copies metadata/schema/translations into dist
│   └── pack.mjs                                 # build: zips dist into an installable bundle
└── gnome-extension/
    ├── src/                                     # TypeScript sources (the source of truth)
    │   ├── extension.ts
    │   └── prefs.ts
    ├── metadata.json
    ├── po/                                       # translations (en source, de provided)
    ├── schemas/
    │   └── org.gnome.shell.extensions.hibernate-windows.gschema.xml
    └── dist/                                     # build output (git-ignored): the installable extension
```

The extension is written in **TypeScript** and compiled to plain, readable ESM
with `tsc` (no bundler). `gnome-extension/dist/` is generated — never edit it by
hand; edit `src/` and rebuild.

## Table of contents

1. [Part 1 — Hibernation: swapfile](#part-1--hibernation-swapfile)
2. [Part 2 — Hibernation: kernel resume config](#part-2--hibernation-kernel-resume-config)
3. [Part 3 — Secure Boot with your own keys (sbctl)](#part-3--secure-boot-with-your-own-keys-sbctl)
4. [Part 4 — Bidirectional dual-boot (the two chains)](#part-4--bidirectional-dual-boot-the-two-chains)
5. [Part 5 — The "Hibernate → Windows" script](#part-5--the-hibernate--windows-script)
6. [Part 6 — GNOME Shell extension](#part-6--gnome-shell-extension)
7. [Part 7 — Auto-remount shared drives on resume](#part-7--auto-remount-shared-drives-on-resume)
8. [Troubleshooting](#troubleshooting)
9. [Safety notes](#safety-notes-read-this)
10. [Appendix — full file listings](#appendix--full-file-listings)

---

## Part 1 — Hibernation: swapfile

Hibernation writes your RAM to disk, so you need swap **≥ your RAM size**.
This example uses a **32 GB** swapfile for 32 GB of RAM.

### 1.1 Btrfs: create a NoCOW swapfile (important!)

Btrfs refuses swapfiles that use copy-on-write. The reliable way is to set the
`NODATACOW` attribute **on an empty file, before writing any data**:

```bash
# Remove any previous attempt
sudo swapoff /swapfile 2>/dev/null
sudo rm -f /swapfile

# Create empty file, mark it NoCOW, THEN fill it
sudo truncate -s 0 /swapfile
sudo chattr +C /swapfile
sudo dd if=/dev/zero of=/swapfile bs=1M count=32768 status=progress   # 32768 MiB = 32 GB
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Verify: the flags MUST contain "C", and swap MUST be active
sudo lsattr /swapfile
swapon --show
```

> **Why `dd` and not `fallocate`/`mkswapfile`?** `dd` writes real extents, so the
> kernel won't reject the swapfile for having holes/unwritten extents. Btrfs'
> `mkswapfile` can also end up copy-on-write if the subvolume gets snapshotted
> afterward (Timeshift/Snapper), which breaks swap with
> `swapon: Invalid argument` and the kernel log `swapfile must not be copy-on-write`.
> See [snapshot warning](#btrfs-snapshots-will-break-a-swapfile-in-a-snapshotted-subvolume).

**ext4 users:** skip `chattr +C`; just `fallocate -l 32G /swapfile` (or `dd`),
then `chmod 600`, `mkswap`, `swapon`.

### 1.2 Make it permanent in `/etc/fstab`

Add this on **its own line** at the end of `/etc/fstab`:

```
/swapfile none swap sw 0 0
```

Then validate — you must see `0 parse errors`:

```bash
sudo systemctl daemon-reload
sudo findmnt --verify
```

---

## Part 2 — Hibernation: kernel resume config

The kernel needs to know **where** the hibernation image lives: which filesystem
(`resume=`) and, for a swapfile, the physical **offset** (`resume_offset=`).

### 2.1 Gather the two values

```bash
# UUID of the filesystem that CONTAINS the swapfile (your root FS)
findmnt -no UUID -T /swapfile

# Btrfs: the resume offset of the swapfile (a plain number)
sudo btrfs inspect-internal map-swapfile -r /swapfile
```

> **ext4/xfs users:** get the offset with
> `sudo filefrag -v /swapfile | awk '$1=="0:"{print $4}'` (strip the trailing `..`).

### 2.2 Add them to the GRUB kernel command line

Edit `/etc/default/grub` and append both to `GRUB_CMDLINE_LINUX_DEFAULT`
(inside the quotes, space-separated). Example:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=UUID=<ROOT_UUID> resume_offset=<OFFSET>"
```

Replace `<ROOT_UUID>` and `<OFFSET>` with the values from 2.1.
**Format matters:** no space after any `=`, and it's `resume=UUID=...` (keep the `UUID=`).

### 2.3 Add the `resume` mkinitcpio hook (this is the step most guides miss)

Edit `/etc/mkinitcpio.conf` and add `resume` to the `HOOKS` array, **after**
`filesystems`:

```
HOOKS=(base udev autodetect microcode kms modconf block keyboard keymap consolefont plymouth filesystems resume)
```

Without this hook, `/sys/power/resume` never gets populated and
`systemctl hibernate` fails with:
`Invalid resume config: resume= is not populated yet resume_offset= is`.

### 2.4 Apply and test

```bash
sudo update-grub          # or: sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo mkinitcpio -P
reboot
```

After the reboot, verify and test:

```bash
cat /sys/power/resume       # must NOT be 0:0
systemctl hibernate
```

Power the machine back on, pick Linux, and your session should return intact.

---

## Part 3 — Secure Boot with your own keys (sbctl)

**Optional.** Do this only if your firmware supports Secure Boot and you want it.
If your machine already boots Windows with Secure Boot on, you'll be enrolling
your own keys **plus** Microsoft's (so Windows keeps working).

> If you don't care about Secure Boot, skip to [Part 4](#part-4--bidirectional-dual-boot-the-two-chains).

### 3.1 Put firmware into Setup Mode

Reboot into UEFI/BIOS and either **clear/reset the Secure Boot keys** or enable
**Setup Mode**. Back in Linux, confirm:

```bash
sbctl status         # Setup Mode: Enabled  (this is what you want here)
```

### 3.2 Create and enroll keys

```bash
sudo sbctl create-keys
sudo sbctl enroll-keys -m      # -m = also enroll Microsoft keys (REQUIRED for dual-boot!)
```

> **Why `-m` is mandatory:** Windows' bootloader is signed by Microsoft. Without
> Microsoft's keys, enabling Secure Boot stops Windows from booting (and some
> firmware needs them for option ROMs / GPU / NVMe).

If enroll fails with `File is immutable: .../efivars/PK-...`, drop the immutable
flag and retry:

```bash
sudo chattr -i /sys/firmware/efi/efivars/PK-*
sudo chattr -i /sys/firmware/efi/efivars/KEK-*
sudo chattr -i /sys/firmware/efi/efivars/db-*
sudo sbctl enroll-keys -m
```

### 3.3 Sign your own EFI binaries

```bash
sudo sbctl verify        # lists what is / isn't signed
sudo sbctl sign -s /boot/efi/EFI/<DISTRO>/grubx64.efi     # e.g. .../EFI/Manjaro/grubx64.efi
sudo sbctl sign -s /boot/efi/EFI/Boot/bootx64.efi
# vmlinuz is usually auto-signed by the sbctl mkinitcpio hook; if verify shows it unsigned:
sudo sbctl sign -s /boot/vmlinuz-<kernel>
sudo sbctl verify
```

> The many `EFI/Microsoft/...` entries showing **"not signed" are normal** — those
> are Microsoft-signed, not yours. **Do not** sign them; `-m` already made them
> trusted. Only your own `grubx64.efi`, `bootx64.efi` and `vmlinuz` must show ✓.

### 3.4 Fix GRUB's `shim_lock` (the "prohibited by secure boot policy" trap)

Arch/Manjaro build GRUB with a `shim_lock` verifier that demands a Microsoft
shim in the chain. When you boot your **own-signed GRUB directly** (no shim),
Secure Boot fails with:

```
shim_lock_verifier_init: prohibited by secure boot policy
```

Fix it by rebuilding GRUB without shim-lock enforcement, then re-signing:

```bash
# 1) Disable it in the config
echo 'GRUB_DISABLE_SHIM_LOCK=y' | sudo tee -a /etc/default/grub

# 2) Reinstall GRUB WITHOUT the shim_lock module
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=<DISTRO> --modules="tpm" --disable-shim-lock

# 3) Also rebuild the removable/fallback loader (some firmware boots via it)
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --removable --modules="tpm" --disable-shim-lock

# 4) Regenerate config and re-sign the freshly written binaries
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo sbctl sign -s /boot/efi/EFI/<DISTRO>/grubx64.efi
sudo sbctl sign -s /boot/efi/EFI/Boot/bootx64.efi
sudo sbctl verify        # your 3 files must be ✓
```

### 3.5 Turn Secure Boot on

Reboot → UEFI → **Secure Boot = Enabled** → boot Linux. Confirm:

```bash
sudo sbctl status        # Setup Mode: Disabled, Secure Boot: Enabled
```

Future kernel/GRUB updates are auto-signed by the sbctl pacman/mkinitcpio hooks.
**Caveat:** if some tool runs `grub-install` *without* `--disable-shim-lock`,
the error returns — just repeat 3.4 steps 2 & 4.

---

## Part 4 — Bidirectional dual-boot (the two chains)

### 4.1 Windows → Linux (make Linux the default)

The reason clicking **Restart in Windows lands you back in Linux** is simply that
**GRUB/Linux is the default UEFI boot entry**, and Windows' *Restart* does a full
reboot that honors the firmware boot order.

Ensure Linux is first in the boot order:

```bash
efibootmgr                       # note the boot number of your Linux/GRUB entry
sudo efibootmgr -o XXXX,YYYY     # put the Linux/GRUB entry (XXXX) first
```

(You can also set the boot order in your UEFI setup screen.)

### 4.2 Linux → Windows (one-shot)

`grub-reboot` sets a **one-time** next entry in GRUB's environment; the boot
after that reverts to your normal default. This is what [Part 5](#part-5--the-hibernate--windows-script)
runs right before hibernating.

> ⚠️ **`grub-reboot` only works if GRUB was built with `GRUB_DEFAULT=saved`.**
> Without it, the one-shot `next_entry` is silently ignored and you just boot
> Linux again. Set it once:
>
> ```bash
> sudo sed -i -E 's|^\s*GRUB_DEFAULT=.*|GRUB_DEFAULT=saved|' /etc/default/grub
> grep -q '^GRUB_DEFAULT=' /etc/default/grub || echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub
> sudo grub-mkconfig -o /boot/grub/grub.cfg
> ```
>
> Leave `GRUB_SAVEDEFAULT` unset/`false`, or the last-booted OS becomes sticky.
> (`install.sh` does all of this for you.)

Find your exact Windows menu title once:

```bash
sudo grep -i "menuentry '" /boot/grub/grub.cfg | cut -d"'" -f2
# e.g. -> Windows Boot Manager (auf /dev/nvme1n1p1)
```

Test the one-shot on its own (no hibernate involved):

```bash
sudo grub-reboot "Windows Boot Manager (auf /dev/nvme1n1p1)" && reboot
# Should boot Windows exactly once, then default back to Linux.
```

### 4.3 Disable Windows Fast Startup (do this!)

Windows "Fast Startup" leaves the Windows system partition (and any NTFS
partitions) in a hibernated, **dirty** state, which is dangerous when Linux mounts
them read-write. In Windows:

> Control Panel → Power Options → *Choose what the power buttons do* →
> *Change settings that are currently unavailable* → **uncheck "Turn on fast startup"**.

This also makes Windows *Shutdown* a true shutdown and keeps NTFS clean for the
Steam-drive sharing described next.

### 4.4 Optional: a "Back to Linux" shortcut on the Windows desktop

Windows *Restart* already returns you to Linux, but a one-click desktop shortcut
is nicer after a gaming session. Create a `Back to Linux.bat` on your Windows
desktop with this content (CRLF line endings):

```bat
@echo off
title Back to Linux
echo Rebooting into Linux...
shutdown /r /t 0
```

Double-clicking it reboots straight into Linux (no elevation needed — normal
users hold the shutdown privilege). Pin it to the taskbar / give it a nicer icon
if you like.

> **Tip:** you can even create this file *from Linux* if the Windows partition is
> mounted, e.g.:
> ```bash
> printf '@echo off\r\ntitle Back to Linux\r\necho Rebooting into Linux...\r\nshutdown /r /t 0\r\n' \
>   > "/mnt/<windows>/Users/<you>/Desktop/Back to Linux.bat"
> ```

---

## Part 5 — The "Hibernate → Windows" script

This script hibernates Linux and pre-selects Windows for the next boot. Because
Linux is frozen while Windows may **write** to shared NTFS drives, it first
**unmounts** those drives. If a drive is busy, it shows a shutdown-style dialog
to kill the blocking processes and continue, or cancel.

### 5.1 Install the script

Copy [`scripts/hibernate-windows.sh`](scripts/hibernate-windows.sh) from this
repo to `~/.local/bin/` and make it executable:

```bash
install -Dm755 scripts/hibernate-windows.sh ~/.local/bin/hibernate-windows.sh
```

**Configure two things** — either edit the defaults at the top of the script, or
(recommended) drop them into `~/.config/hibernate-windows.conf`, which the script
sources at runtime so you never have to touch the script itself:

```bash
cat > ~/.config/hibernate-windows.conf <<'EOF'
WIN_ENTRY="Windows Boot Manager (auf /dev/nvme1n1p1)"
DRIVES=(/mnt/win_data)
EOF
```

- `WIN_ENTRY` — your exact Windows GRUB title (from [4.2](#42-linux--windows-one-shot)).
- `DRIVES` — the mount points of your shared NTFS drives (or empty `()` if none).

(`install.sh` writes this config file for you with the detected values.)

Required tools (install if missing): `zenity`, `lsof`, `psmisc` (for `fuser`),
`libnotify` (for `notify-send`).

```bash
sudo pacman -S --needed zenity lsof psmisc libnotify
```

### 5.2 Allow the root commands without a password

The script runs a few root commands non-interactively (it's launched from the
GNOME menu, with no terminal to type a password into). Grant just those:

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/grub-reboot, /usr/bin/grub-editenv, /usr/bin/umount, /usr/bin/fuser" \
  | sudo tee /etc/sudoers.d/hibernate-windows
sudo chmod 440 /etc/sudoers.d/hibernate-windows
sudo visudo -c        # must report "parsed OK"
```

`grub-editenv` is used to reset the one-shot Windows boot if hibernation itself
fails (see the script), so you don't accidentally boot into Windows on your next
normal reboot.

`systemctl hibernate` itself needs no sudo — polkit allows it for the active session.

### 5.3 (Optional) Auto-mount the shared drives at boot

By default a fresh install does **not** auto-mount your Windows/NTFS data drives.
Adding them to `/etc/fstab` mounts them on every boot — handy so your **Steam
library is always there** without clicking around in Files first.

```bash
lsblk -f                        # find the UUIDs of your NTFS partitions
sudo mkdir -p /mnt/win_nvme0    # one mountpoint per drive
```

Add one line per drive to `/etc/fstab` (read-write for your user, `nofail` so a
missing drive never blocks boot):

```
UUID=<NTFS_UUID> /mnt/win_nvme0 ntfs-3g uid=1000,gid=1000,rw,user,exec,umask=000,nofail 0 0
```

```bash
sudo systemctl daemon-reload && sudo mount -a
```

**You don't have to do this.** If you'd rather keep it manual, just open the
drive in GNOME Files when you need it — no fstab entry required.

> **How this ties into [Part 7](#part-7--auto-remount-shared-drives-on-resume):**
> the resume-remount hook only matters if the drives are actually mounted during
> your session (auto-mounted here, or mounted by hand) and the script unmounts
> them for the Windows trip. If you never keep NTFS drives mounted while working,
> you can skip Part 7 and leave `DRIVES=()` empty in the script.

---

## Part 6 — GNOME Shell extension

A small extension that adds **Hibernate** and **Hibernate → Windows** to the
system power menu, with a preferences page to hide built-in entries (e.g.
*Suspend*). Written in **TypeScript**, compiled to plain ESM. GNOME 45+, tested
on GNOME 50 / Wayland.

### 6.1 Install

Install the packaged zip (from a release, or `npm run pack` — see
[building the extension](#the-gnome-extension-install-a-prebuilt-zip-or-build-it-yourself)):

```bash
gnome-extensions install --force hibernate-windows@salaty.shell-extension.zip
```

This unpacks it into `~/.local/share/gnome-shell/extensions/` and compiles the
schema for you.

> Rename the UUID (`hibernate-windows@salaty`) to your own handle if you like —
> it must match the folder name and the `uuid` field in `metadata.json` (and the
> `config.uuid` in `package.json`).

### 6.2 Enable

On **Wayland you must log out and back in** for GNOME to pick up a new extension.
Then:

```bash
gnome-extensions enable hibernate-windows@salaty
gnome-extensions prefs  hibernate-windows@salaty   # open settings
```

Open the power menu → the two entries appear at the top.

### 6.3 How it works

- Hooks into `Main.panel.statusArea.quickSettings._system._systemItem.menu`.
- Inserts two `PopupMenuItem`s at the top of the power menu.
- Built-in entries are hidden by matching their (localized) labels — German and
  English are covered in `MATCHERS`; add your language there if needed.
- Preferences are stored via GSettings and applied live (on change and each time
  the menu opens).

---

## Part 7 — Auto-remount shared drives on resume

**Optional** — only needed if you keep NTFS drives mounted during your session
(see [5.3](#53-optional-auto-mount-the-shared-drives-at-boot)). This closes the
loop on the round trip. The script unmounts your shared NTFS
drives before hibernating — but **`fstab` is not re-processed on resume** (only on
a real boot). Without this step you'd wake back into Linux with the Steam drives
missing until you mount them by hand.

A systemd **system-sleep** hook remounts them automatically after every resume
(runs as root, independent of the script):

```bash
sudo tee /usr/lib/systemd/system-sleep/remount-steam-drives >/dev/null <<'EOF'
#!/bin/sh
# Remount shared NTFS/Steam drives after waking from hibernate/suspend.
# (fstab is not re-processed on resume.) Adjust DRIVES to your mount points.
DRIVES="/mnt/win_platte_1 /mnt/win_nvme1_a /mnt/win_nvme0"
case "$1" in
  post)
    for m in $DRIVES; do
      mountpoint -q "$m" || mount "$m" 2>/dev/null
    done
    ;;
esac
EOF
sudo chmod +x /usr/lib/systemd/system-sleep/remount-steam-drives
```

**Why this is safe:** a fresh mount after wake reads the NTFS metadata from disk
again, so there is no stale-cache corruption. On a normal suspend/resume nothing
happens because the drives are already mounted (`mountpoint -q` skips them).

> The hook receives `$1` = `pre|post` and `$2` = `suspend|hibernate|…`. We only
> act on `post`, so it covers hibernate *and* normal suspend resume.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `swapon: Invalid argument`, log says *swapfile must not be copy-on-write* | Btrfs swapfile is CoW. Recreate with `chattr +C` on the empty file first ([1.1](#11-btrfs-create-a-nocow-swapfile-important)). |
| `Invalid resume config: resume= is not populated yet resume_offset= is` | Missing `resume` mkinitcpio hook ([2.3](#23-add-the-resume-mkinitcpio-hook-this-is-the-step-most-guides-miss)) and/or you haven't rebooted after `mkinitcpio -P`. |
| Hibernate works but session isn't restored | Wrong `resume_offset`, or swap not active at boot (`swapon --show` empty). Re-check [1.2](#12-make-it-permanent-in-etcfstab) and [2.1](#21-gather-the-two-values). |
| `shim_lock_verifier_init: prohibited by secure boot policy` | GRUB shim-lock trap — do [3.4](#34-fix-grubs-shim_lock-the-prohibited-by-secure-boot-policy-trap). |
| Secure Boot on → Windows won't boot | You enrolled keys without `-m`. Re-run `sudo sbctl enroll-keys -m`. |
| Extension entries missing after relogin | Check the log: `journalctl --user -b -o cat /usr/bin/gnome-shell | grep -i hibernate-windows`. A *"power menu not found"* line means the GNOME menu path changed — update the object path in `extension.js`. |
| Unmount dialog never lets me continue | The blocking app keeps re-opening files. Close it manually (e.g. quit Steam fully) and retry. |

---

## Safety notes (read this)

### Shared NTFS + hibernation = corruption risk

If Linux is **hibernated** with an NTFS partition mounted read-write, and then
**Windows writes** to that same partition, Linux resumes with a stale view of the
filesystem → **corruption** of that NTFS partition. That's the whole reason the
script unmounts shared drives before the handoff. Your Linux (Btrfs) system
partition is safe — Windows can't touch it.

Combined mitigations used here:
1. Unmount shared NTFS drives before hibernating (the script).
2. **Disable Windows Fast Startup** ([4.3](#43-disable-windows-fast-startup-do-this)).

### Btrfs snapshots will break a swapfile in a snapshotted subvolume

If you run Timeshift/Snapper on the subvolume that holds `/swapfile`, each
snapshot makes the swapfile's extents shared → CoW again → swap/hibernation
breaks, and the `resume_offset` can change. **Advanced fix:** put the swapfile on
a dedicated subvolume that is excluded from snapshots:

```bash
sudo btrfs subvolume create /swap
sudo chattr +C /swap
# create /swap/swapfile exactly as in Part 1, use its own offset,
# and add it to fstab. Keep this subvolume out of your snapshot config.
```

---

## Appendix — full file listings

> These listings are for reading/reference. The canonical, ready-to-use files
> live in the repo under [`scripts/`](scripts/) and
> [`gnome-extension/`](gnome-extension/), and `install.sh` writes them for you.

### A. `scripts/hibernate-windows.sh` → `~/.local/bin/hibernate-windows.sh`

```bash
#!/usr/bin/env bash
# Freeze Linux and boot Windows ONCE on the next start; afterwards GRUB reverts
# to your normal default (Linux). Unmounts shared NTFS/Steam drives first (to
# avoid corruption while Windows writes to them). If a drive is busy, a
# shutdown-style dialog offers to kill the blocking apps and continue, or cancel.
set -uo pipefail

# === EDIT: exact Windows GRUB menu title ===
#   sudo grep -i "menuentry '" /boot/grub/grub.cfg | cut -d"'" -f2
WIN_ENTRY="Windows Boot Manager (auf /dev/nvme1n1p1)"

# === EDIT: shared NTFS mount points (empty () if you have none) ===
DRIVES=(/mnt/win_platte_1 /mnt/win_nvme1_a /mnt/win_nvme0)

TITLE="Hibernate → Windows"

# Unmount one drive; on "busy" show a dialog with the blocking processes.
# return 0 = unmounted/not needed, 1 = cancelled/failed.
unmount_or_ask() {
    local m="$1"
    mountpoint -q "$m" || return 0
    sudo umount "$m" 2>/dev/null && return 0

    while true; do
        local list
        list=$(lsof -w "$m" 2>/dev/null | awk 'NR>1 {print "• "$1"  (PID "$2", "$3")"}' | sort -u)
        [ -z "$list" ] && list="• (unknown processes)"

        if zenity --question --title="$TITLE" --width=460 \
            --icon-name=drive-harddisk \
            --ok-label="Kill & continue" --cancel-label="Cancel" \
            --text="<b>$m</b> is still busy and cannot be unmounted.

These processes are using it:
$list

<i>Killing forces them closed (unsaved progress is lost).</i>"
        then
            fuser -km "$m" 2>/dev/null
            sudo fuser -km "$m" 2>/dev/null
            sleep 2
            sudo umount "$m" 2>/dev/null && return 0
        else
            return 1
        fi
    done
}

for m in "${DRIVES[@]}"; do
    if ! unmount_or_ask "$m"; then
        notify-send "$TITLE" "Cancelled — Linux keeps running normally." 2>/dev/null || true
        exit 1
    fi
done

if ! sudo grub-reboot "$WIN_ENTRY"; then
    zenity --error --title="$TITLE" --width=400 \
        --text="Could not set the next boot to Windows (grub-reboot)." 2>/dev/null || true
    exit 1
fi

# systemctl hibernate only returns AFTER resume (exit 0). If freezing fails, the
# one-shot Windows boot would linger -> reset it so the next reboot stays Linux.
if ! systemctl hibernate; then
    sudo grub-editenv - unset next_entry 2>/dev/null
    zenity --error --title="$TITLE" --width=400 \
        --text="Hibernation failed – the one-shot Windows boot was reset. Linux keeps running." 2>/dev/null || true
    exit 1
fi
```

### B. `metadata.json`

```json
{
  "uuid": "hibernate-windows@salaty",
  "name": "Hibernate → Windows",
  "description": "Adds 'Hibernate' and 'Hibernate → Windows' entries to the power menu (freezes Linux and pre-selects Windows for the next boot). Includes a preferences page to hide default power-menu entries.",
  "shell-version": ["48", "49", "50"],
  "settings-schema": "org.gnome.shell.extensions.hibernate-windows",
  "version": 1
}
```

### C. `extension.js`

```javascript
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const SCRIPT =
    GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'hibernate-windows.sh']);

// Built-in entries are matched by their (localized) label. German + English.
const MATCHERS = {
    'hide-suspend':  ['bereitschaft', 'suspend'],
    'hide-restart':  ['neustart', 'restart'],
    'hide-poweroff': ['ausschalten', 'power off'],
    'hide-logout':   ['abmelden', 'log out'],
};

export default class HibernateWindowsExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._ownItems = [];

        this._menu = Main.panel.statusArea.quickSettings?._system?._systemItem?.menu;
        if (!this._menu) {
            logError(new Error('hibernate-windows: power menu not found ' +
                '(quickSettings._system._systemItem.menu) – GNOME API may have changed.'));
            return;
        }

        this._winItem = new PopupMenu.PopupMenuItem('Ruhezustand → Windows');
        this._winItem.connect('activate', () => this._spawn([SCRIPT]));

        this._hibItem = new PopupMenu.PopupMenuItem('Ruhezustand');
        this._hibItem.connect('activate', () => this._spawn(['systemctl', 'hibernate']));

        this._menu.addMenuItem(this._hibItem, 0);
        this._menu.addMenuItem(this._winItem, 0);
        this._ownItems.push(this._winItem, this._hibItem);

        this._settingsId = this._settings.connect('changed', () => this._apply());
        this._openId = this._menu.connect('open-state-changed', (_m, open) => {
            if (open)
                this._apply();
        });

        this._apply();
    }

    _apply() {
        if (!this._menu)
            return;

        this._winItem.visible = this._settings.get_boolean('show-hibernate-windows');
        this._hibItem.visible = this._settings.get_boolean('show-hibernate');

        for (const item of this._menu._getMenuItems()) {
            if (item === this._winItem || item === this._hibItem)
                continue;
            const text = item?.label?.text?.toLowerCase();
            if (!text)
                continue;
            for (const [key, needles] of Object.entries(MATCHERS)) {
                if (needles.some(n => text.includes(n))) {
                    item.visible = !this._settings.get_boolean(key);
                    break;
                }
            }
        }
    }

    disable() {
        if (this._menu && this._openId)
            this._menu.disconnect(this._openId);
        if (this._settings && this._settingsId)
            this._settings.disconnect(this._settingsId);

        if (this._menu) {
            for (const item of this._menu._getMenuItems()) {
                if (item === this._winItem || item === this._hibItem)
                    continue;
                const text = item?.label?.text?.toLowerCase();
                if (!text)
                    continue;
                if (Object.values(MATCHERS).some(ns => ns.some(n => text.includes(n))))
                    item.visible = true;
            }
        }

        for (const item of this._ownItems ?? [])
            item.destroy();

        this._ownItems = null;
        this._winItem = null;
        this._hibItem = null;
        this._menu = null;
        this._settings = null;
        this._openId = null;
        this._settingsId = null;
    }

    _spawn(argv) {
        try {
            Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
        } catch (e) {
            logError(e, 'hibernate-windows: could not start command');
        }
    }
}
```

### D. `prefs.js`

```javascript
import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

export default class HibernateWindowsPrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const page = new Adw.PreferencesPage({
            title: 'Entries',
            icon_name: 'system-shutdown-symbolic',
        });

        const own = new Adw.PreferencesGroup({
            title: 'Custom entries',
            description: 'Extra entries in the power menu',
        });
        own.add(this._switch(settings, 'show-hibernate-windows', 'Hibernate → Windows'));
        own.add(this._switch(settings, 'show-hibernate', 'Hibernate'));
        page.add(own);

        const std = new Adw.PreferencesGroup({
            title: 'Hide default entries',
            description: 'Hide the built-in power-menu entries',
        });
        std.add(this._switch(settings, 'hide-suspend', 'Hide Suspend'));
        std.add(this._switch(settings, 'hide-restart', 'Hide Restart'));
        std.add(this._switch(settings, 'hide-poweroff', 'Hide Power Off'));
        std.add(this._switch(settings, 'hide-logout', 'Hide Log Out'));
        page.add(std);

        window.add(page);
    }

    _switch(settings, key, title) {
        const row = new Adw.SwitchRow({title});
        settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT);
        return row;
    }
}
```

### E. `schemas/org.gnome.shell.extensions.hibernate-windows.gschema.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="org.gnome.shell.extensions.hibernate-windows"
          path="/org/gnome/shell/extensions/hibernate-windows/">
    <key name="show-hibernate-windows" type="b"><default>true</default></key>
    <key name="show-hibernate"         type="b"><default>true</default></key>
    <key name="hide-suspend"           type="b"><default>false</default></key>
    <key name="hide-restart"           type="b"><default>false</default></key>
    <key name="hide-poweroff"          type="b"><default>false</default></key>
    <key name="hide-logout"            type="b"><default>false</default></key>
  </schema>
</schemalist>
```

---

## License

Do whatever you want with this — MIT-style, no warranty. If your machine catches
fire, unmounts the wrong drive, or your cat enables Secure Boot, that's on you. 🐱‍💻

*Guide reflects a working setup on Manjaro, GNOME 50 (Wayland), GRUB, Btrfs, 32 GB RAM.*
