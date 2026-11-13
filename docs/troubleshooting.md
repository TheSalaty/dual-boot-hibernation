# Troubleshooting

Start with `os-switch status`. It checks the whole chain and names what is
missing.

| Symptom | Cause / fix |
| --- | --- |
| *Hibernate → Windows* freezes, but Linux starts again | The firmware ignored the one-time boot entry. Test it alone: `sudo efibootmgr -n <Windows entry> && reboot`. If that also lands in Linux, re-run `install.sh` and choose the GRUB fallback. |
| With `after_freeze = reboot` the machine hangs with a black screen after writing the image | That mode does not work on this machine. Go back to `after_freeze = rtc`. |
| The machine powers off and stays off | The clock does not switch this board on. Look for "RTC Alarm" or "Wake on RTC" in the firmware setup and allow the system to set it ("By OS"). Pressing the power button starts Windows in the meantime. |
| With `after_freeze = rtc` the screen comes back and the handoff starts again | The clock fired before the machine was off. `os-switch` adds 10 seconds and tries again, up to twice, and remembers the extra time. If the machine then stays off noticeably long before it starts, lower `rtc_base_secs`. |
| *Hibernate → Windows* takes much longer than a plain hibernate, or fails now and then | Look for a device that keeps failing: `journalctl -k -b \| grep -c "Cannot enable"`. A USB port that retries every few seconds keeps the kernel busy while it freezes. Replace the cable or use another port. |
| After a Windows update the machine sits in Linux mid-update | A one-time boot entry covers one start only. `sticky = yes` fixes this once the Windows companion exists; until then, finish updates before you return. |
| `swapon: Invalid argument`, log says *swapfile must not be copy-on-write* | The Btrfs swap file is copy-on-write. Recreate it with `chattr +C` on the empty file first ([setup guide 1.1](setup-guide.md#11-btrfs-create-a-nocow-swapfile-important)). |
| `Invalid resume config: resume= is not populated yet resume_offset= is` | The `resume` mkinitcpio hook is missing ([setup guide 2.3](setup-guide.md#23-add-the-resume-mkinitcpio-hook-this-is-the-step-most-guides-miss)), or you have not rebooted since `mkinitcpio -P`. |
| Hibernate works but the session is not restored | Wrong `resume_offset`, or swap is not active at boot (`swapon --show` is empty). |
| `shim_lock_verifier_init: prohibited by secure boot policy` | GRUB's shim-lock check ([setup guide 3.4](setup-guide.md#34-fix-grubs-shim_lock-the-prohibited-by-secure-boot-policy-trap)). |
| Secure Boot on → Windows won't start | Keys were enrolled without Microsoft's. Re-run `sudo sbctl enroll-keys -m`. |
| The unmount dialog keeps coming back | A program reopens files on the drive. Quit it fully (Steam, for example) and try again. |
| A shared drive is missing after the trip; Steam shows a library as 0 B | The drive was not mounted again. `os-switch status` shows whether `os-switch-resume.service` is enabled. Quick fix: `sudo mount -a`, then restart Steam. |
| Steam Cloud conflicts; clock off by an hour or two after switching | Windows keeps the hardware clock in local time ([setup guide 4.2](setup-guide.md#42-make-windows-keep-the-hardware-clock-in-utc)). |
| Power-menu entries missing after logging in again | `journalctl --user -b -o cat /usr/bin/gnome-shell \| grep -i hibernate-windows`. *"power menu not found"* means GNOME changed its internal menu path. |
| A power-menu entry does nothing | The extension calls `/usr/local/bin/os-switch`. Check that it exists, then run `os-switch windows` in a terminal to see the message. |
