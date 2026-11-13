#!/usr/bin/env bash
# End-to-end tests of os-switch in the VM (see vm.sh, provision.sh, install.sh).
# shellcheck disable=SC2016  # $(…) in single quotes runs in the guest on purpose
# Usage: run.sh [test…]   Tests: reboot-windows windows-reboot windows-rtc windows-rtc-retry windows-fails
set -uo pipefail
cd "$(dirname "$0")/../.." || exit
VM=tests/vm/vm.sh
SERIAL="${OS_SWITCH_VM_DIR:-$HOME/.cache/os-switch-vm}/serial.log"
fails=0

windows_boots() { grep -ac "FAKE-WINDOWS started" "$SERIAL"; }
guest() { $VM ssh "$@"; }
check() { # check "what" command…
    local what=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  ok    $what"; else echo "  FAIL  $what"; fails=$((fails + 1)); fi
}
# Start a command in the guest that survives the SSH connection going away.
detached() { guest "setsid nohup $* >~/osw.log 2>&1 </dev/null &"; }
# Wait until the fake Windows has started once more than `$1`, then for Linux.
through_windows() {
    local before=$1
    for _ in $(seq 60); do [ "$(windows_boots)" -gt "$before" ] && break; sleep 2; done
    sleep 8 # fake Windows waits 5 s, then restarts
    $VM wait-ssh
}
clean_state() {
    check "no one-time boot entry left" guest '! efibootmgr | grep -q ^BootNext'
    check "Linux is first in the boot order" guest 'efibootmgr | grep -q "^BootOrder: $(efibootmgr | sed -n "s/^BootCurrent: //p")"'
    check "no hibernate-mode override left" guest '! test -e /etc/systemd/sleep.conf.d/90-os-switch.conf'
}

t_reboot_windows() {
    echo "reboot-windows"
    local before boot; before=$(windows_boots); boot=$(guest cat /proc/sys/kernel/random/boot_id)
    detached os-switch reboot-windows
    through_windows "$before"
    check "Windows started exactly once" [ "$(windows_boots)" -eq $((before + 1)) ]
    check "Linux was restarted, not resumed" [ "$(guest cat /proc/sys/kernel/random/boot_id)" != "$boot" ]
    clean_state
}

t_windows_reboot() {
    echo "windows (after_freeze = reboot)"
    guest "sudo sed -i -E 's/^#?after_freeze = .*/after_freeze = reboot/' /etc/os-switch.conf"
    local before boot; before=$(windows_boots); boot=$(guest cat /proc/sys/kernel/random/boot_id)
    detached os-switch windows
    through_windows "$before"
    check "Windows started exactly once" [ "$(windows_boots)" -eq $((before + 1)) ]
    check "the Linux session was resumed" [ "$(guest cat /proc/sys/kernel/random/boot_id)" = "$boot" ]
    sleep 3 # let the clean-up after waking finish
    clean_state
    echo "  log:  $(guest cat osw.log | tr '\n' ' ')"
}

t_windows_rtc() {
    echo "windows (after_freeze = rtc; the test plays the clock and powers the VM on)"
    guest "sudo sed -i -E 's/^#?after_freeze = .*/after_freeze = rtc/' /etc/os-switch.conf"
    local boot; boot=$(guest cat /proc/sys/kernel/random/boot_id)
    detached os-switch windows
    for _ in $(seq 60); do $VM running || break; sleep 2; done
    check "the machine powered off" bash -c "! $VM running"
    $VM start # the serial log starts empty again
    through_windows 0
    check "Windows started exactly once" [ "$(windows_boots)" -eq 1 ]
    check "the Linux session was resumed" [ "$(guest cat /proc/sys/kernel/random/boot_id)" = "$boot" ]
    sleep 5 # let the clean-up after waking finish
    clean_state
    check "the wake-up alarm was cleared" guest '[ -z "$(cat /sys/class/rtc/rtc0/wakealarm)" ]'
    echo "  log:  $(guest cat osw.log | tr '\n' ' ')"
}

# The VM cannot be made to wake early, so the first hibernation is made to
# fail the way an early wake-up does: started, then cancelled.
t_windows_rtc_retry() {
    echo "windows (after_freeze = rtc, first attempt cancelled)"
    guest "sudo sed -i -E 's/^#?after_freeze = .*/after_freeze = rtc/' /etc/os-switch.conf
        sudo rm -f /var/lib/os-switch/rtc-extra
        sudo mkdir -p /run/systemd/system/systemd-hibernate.service.d
        printf '[Service]\nExecStartPre=/bin/sh -c \"[ -e /run/failed-once ] || { touch /run/failed-once; exit 1; }\"\n' |
            sudo tee /run/systemd/system/systemd-hibernate.service.d/fail-once.conf >/dev/null
        sudo rm -f /run/failed-once; sudo systemctl daemon-reload"
    local boot; boot=$(guest cat /proc/sys/kernel/random/boot_id)
    detached os-switch windows
    for _ in $(seq 60); do $VM running || break; sleep 2; done
    check "the machine powered off on the second attempt" bash -c "! $VM running"
    $VM start
    through_windows 0
    check "Windows started exactly once" [ "$(windows_boots)" -eq 1 ]
    check "the Linux session was resumed" [ "$(guest cat /proc/sys/kernel/random/boot_id)" = "$boot" ]
    check "the extra time was remembered" guest '[ "$(cat /var/lib/os-switch/rtc-extra)" = 10 ]'
    sleep 5
    clean_state
    guest "sudo rm -rf /run/systemd/system/systemd-hibernate.service.d /var/lib/os-switch/rtc-extra; sudo systemctl daemon-reload"
    echo "  log:  $(guest cat osw.log | tr '\n' ' ')"
}

# Hibernation that never works must leave Linux running and Windows deselected.
t_windows_fails() {
    echo "windows (hibernation always fails)"
    guest "sudo sed -i -E 's/^#?after_freeze = .*/after_freeze = reboot/' /etc/os-switch.conf
        sudo mkdir -p /run/systemd/system/systemd-hibernate.service.d
        printf '[Service]\nExecStartPre=/bin/false\n' |
            sudo tee /run/systemd/system/systemd-hibernate.service.d/fail.conf >/dev/null
        sudo systemctl daemon-reload"
    check "os-switch reports the failure" guest '! os-switch windows 2>~/osw.log'
    check "it says why" guest 'grep -q "Hibernation failed" ~/osw.log'
    clean_state
    guest "sudo rm -rf /run/systemd/system/systemd-hibernate.service.d; sudo systemctl daemon-reload"
}

[ $# -gt 0 ] || set -- reboot-windows windows-reboot windows-rtc windows-rtc-retry windows-fails
for t in "$@"; do "t_${t//-/_}"; done
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails check(s) failed"; exit 1; }
