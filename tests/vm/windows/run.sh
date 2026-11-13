#!/usr/bin/env bash
# End-to-end test of the Windows side: a Windows 11 VM with WSL gets the disk
# of the Linux test VM and has to run that Linux, start its programs, leave it
# clean, and only look at it, without writing a byte, while Linux is hibernated.
#
# Needs both VMs set up and switched off (see ../vm.sh and winvm.sh).
# shellcheck disable=SC2016  # $… in single quotes runs in the guest on purpose
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit
LIN=tests/vm/vm.sh
WIN=tests/vm/windows/winvm.sh
WSH=tests/vm/windows/wsh.sh
BASE="${OS_SWITCH_VM_DIR:-$HOME/.cache/os-switch-vm}"
SCP=(scp -q -i "$BASE/id" -P 2223 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
PS='powershell -NoProfile -ExecutionPolicy Bypass -File'
INSTALLED='"C:\Program Files\os-switch\os-switch.ps1"'
fails=0

check() { # check "what" command…
    local what=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  ok    $what"; else echo "  FAIL  $what"; fails=$((fails + 1)); fi
}
win() { timeout 120 $WIN ssh "$@"; }
linux_state() { win "$PS $INSTALLED status" | sed -n 's/^Linux in WSL: *//p' | tr -d '\r'; }
wait_state() { # state seconds
    for _ in $(seq $(($2 / 5))); do [ "$(linux_state)" = "$1" ] && return 0; sleep 5; done
    return 1
}
win_off() {
    win 'shutdown /s /t 1' >/dev/null 2>&1
    for _ in $(seq 60); do $WIN running || break; sleep 3; done
    $WIN running && $WIN stop
    rm -f "$BASE/win/pid"
}
linux_off() { for _ in $(seq 60); do $LIN running || return 0; sleep 2; done; return 1; }

if $LIN running || $WIN running; then echo "switch both VMs off first" >&2; exit 2; fi

echo "install and start"
$WIN start && $WIN wait-ssh 40 || exit 1
win 'New-Item -ItemType Directory -Force C:\osw\wsl | Out-Null'
"${SCP[@]}" windows/os-switch.ps1 test@127.0.0.1:C:/osw/os-switch.ps1
"${SCP[@]}" windows/wsl/os-switch-wsl test@127.0.0.1:C:/osw/wsl/os-switch-wsl
win "if (Test-Path $INSTALLED) { $PS $INSTALLED uninstall | Out-Null }"
check "the installer runs" win "$PS C:\\osw\\os-switch.ps1 install -DesktopShortcut"
check "Linux is running in WSL" wait_state running 120
check "fstab mounts of the Linux installation are there" $WSH <<<'os-switch-wsl run test -f /mnt/sub/hello.txt'
check "nothing failed to start in Linux" $WSH <<<'[ "$(os-switch-wsl run systemctl is-system-running)" = running ]'
check "Linux programs are in the Start menu" win 'if (-not (Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Linux\Calculator (Linux).lnk")) { exit 1 }'
check "each has an icon" win 'if (-not (Test-Path "$env:LOCALAPPDATA\os-switch\icons\org.gnome.Calculator.ico")) { exit 1 }'

echo "start a program through its Start menu entry"
win '$l = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Linux\Calculator (Linux).lnk"); Start-Process $l.TargetPath -ArgumentList $l.Arguments -Wait'
sleep 8
check "the program keeps running after the launcher has returned" $WSH <<<'os-switch-wsl run pgrep -f gnome-calculator'
marker="written in WSL $(date +%s)"
$WSH <<<"os-switch-wsl run sh -c 'echo \"$marker\" > ~/from-wsl.txt'"

echo "Back to Linux (the test VM has no Linux to start, so Windows comes back)"
win 'Start-ScheduledTask "os-switch back to linux"'
sleep 20
for _ in $(seq 40); do timeout 8 $WIN ssh exit 2>/dev/null || break; sleep 3; done
check "Windows restarted" $WIN wait-ssh 40
check "Linux starts by itself after sign-in" wait_state running 180
check "Linux had been shut down cleanly before the restart" $WSH <<<'os-switch-wsl run sh -c "journalctl -b -1 --no-pager -n 40 2>/dev/null | grep -q \"Reached target.*Shutdown\|Shutting down\|System Power Off\""'

echo "hand the disk back and start the real Linux"
check "detach" win "$PS $INSTALLED detach"
win_off
$LIN start && $LIN wait-ssh || exit 1
check "the change made in Windows is there" [ "$($LIN ssh cat from-wsl.txt)" = "$marker" ]
check "the filesystem reports no errors" $LIN ssh '! sudo journalctl -b -k --no-pager | grep -i -E "btrfs.*(error|corrupt)"'

echo "hibernate Linux, then start Windows: view only"
$LIN ssh 'mkdir -p ~/Documents && echo report > ~/Documents/report.txt && sync'
boot=$($LIN ssh cat /proc/sys/kernel/random/boot_id)
$LIN ssh 'setsid nohup os-switch hibernate >~/osw.log 2>&1 </dev/null &'
check "Linux hibernated and powered off" linux_off
cp --reflink=auto "$BASE/disk.qcow2" "$BASE/disk.before.qcow2"
$WIN start && $WIN wait-ssh 40 || exit 1
check "the hibernated Linux starts view only" wait_state view-only 180
check "its disks are write-blocked" $WSH <<<'for d in $(cat /run/os-switch/disks); do [ "$(blockdev --getro "$d")" = 1 ] || exit 1; done'
check "its programs are in the Start menu" win 'if (-not (Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Linux\Calculator (Linux).lnk")) { exit 1 }'
win '$l = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Linux\Calculator (Linux).lnk"); Start-Process $l.TargetPath -ArgumentList $l.Arguments -Wait'
sleep 8
check "a program starts" $WSH <<<'os-switch-wsl run pgrep -f gnome-calculator'
check "files can be read" $WSH <<<'[ "$(os-switch-wsl run cat Documents/report.txt)" = report ] && os-switch-wsl run test -f /mnt/sub/hello.txt'
check "files cannot be changed" $WSH <<<'! os-switch-wsl run sh -c "echo x >> Documents/report.txt" && ! os-switch-wsl run touch Documents/new.txt && ! os-switch-wsl run sh -c "echo x >> from-wsl.txt" && ! os-switch-wsl run sudo -n touch /mnt/sub/new.txt'
check "programs can write their settings" $WSH <<<'os-switch-wsl run sh -c "mkdir -p .config && echo x > .config/view-test"'
check "no service of the installation runs" $WSH <<<'! os-switch-wsl run systemctl is-active -q sshd.service'
# No detach, no clean stop: the worst case, Windows just goes away.
win_off

# Windows itself clears the "dirty" flag in the boot sector of the Linux EFI
# partition (one byte). Everything else has to be identical.
qemu-img convert -O raw "$BASE/disk.before.qcow2" "$BASE/before.raw"
qemu-img convert -O raw "$BASE/disk.qcow2" "$BASE/after.raw"
efi_start=$((0x1000 * 512))
changed=$(cmp -l "$BASE/before.raw" "$BASE/after.raw" | awk -v s="$efi_start" '$1 - 1 < s || $1 - 1 >= s + 512 { n++ } END { print n + 0 }')
rm -f "$BASE/before.raw" "$BASE/after.raw" "$BASE/disk.before.qcow2"
check "no byte of the Linux disk changed outside the EFI boot sector" [ "$changed" -eq 0 ]

$LIN start && $LIN wait-ssh || exit 1
sleep 30
check "Linux resumed its frozen session" [ "$($LIN ssh cat /proc/sys/kernel/random/boot_id)" = "$boot" ]
check "what programs wrote in Windows is gone" $LIN ssh '! test -e .config/view-test'
check "the filesystem reports no errors after resume" $LIN ssh '! sudo journalctl -b -k --no-pager | grep -i -E "btrfs.*(error|corrupt)"'
$LIN ssh 'sudo systemctl poweroff' 2>/dev/null
linux_off

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails check(s) failed"; exit 1; }
