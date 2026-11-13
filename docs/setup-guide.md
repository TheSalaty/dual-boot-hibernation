# Setup guide: hibernation, Secure Boot, shared drives

What `install.sh` does for you, step by step, for doing it by hand or for
understanding it. Written for Arch-based systems with GRUB; tested on Manjaro
with Btrfs. The handoff itself is described in [how-it-works.md](how-it-works.md).

- [Part 1 — Hibernation: swapfile](#part-1--hibernation-swapfile)
- [Part 2 — Hibernation: kernel resume config](#part-2--hibernation-kernel-resume-config)
- [Part 3 — Secure Boot with your own keys (sbctl)](#part-3--secure-boot-with-your-own-keys-sbctl)
- [Part 4 — Windows settings and shared drives](#part-4--windows-settings-and-shared-drives)

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

> If you don't care about Secure Boot, skip to [Part 4](#part-4--windows-settings-and-shared-drives).

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

## Part 4 — Windows settings and shared drives

Windows not installed yet? See [windows-install.md](windows-install.md) first.

### 4.1 Turn off Windows Fast Startup and hibernation

Fast Startup leaves NTFS partitions in a hibernated, dirty state, which is
dangerous as soon as Linux mounts them read-write. In an administrator prompt
in Windows:

```bat
powercfg /h off
```

This turns off Windows hibernation and Fast Startup together and makes
*Shut down* a real shutdown.

### 4.2 Make Windows keep the hardware clock in UTC

Linux keeps the hardware clock in UTC, Windows in local time. Without this the
clock is an hour or two off after every switch, and Steam Cloud reports
conflicts. In an administrator prompt in Windows, then restart:

```bat
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

### 4.3 (Optional) Mount shared NTFS drives at boot

Handy when a Steam library lives on an NTFS drive that Windows also uses.

```bash
lsblk -f                        # find the UUIDs of your NTFS partitions
sudo mkdir -p /mnt/win_data     # one mount point per drive
```

One line per drive in `/etc/fstab` (`nofail` so a missing drive never blocks the
boot):

```
UUID=<NTFS_UUID> /mnt/win_data ntfs-3g uid=1000,gid=1000,rw,user,exec,umask=000,nofail 0 0
```

```bash
sudo systemctl daemon-reload && sudo mount -a
```

`os-switch` finds these drives by itself: it unmounts them before the handoff
and mounts them again afterwards. There is no list to maintain.

---

## Btrfs snapshots will break a swapfile in a snapshotted subvolume

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


