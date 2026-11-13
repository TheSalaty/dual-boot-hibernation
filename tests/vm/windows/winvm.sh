#!/usr/bin/env bash
# A Windows 11 test machine in QEMU, with WSL inside (nested virtualization)
# and the Linux test disk of ../vm.sh attached as a second disk.
# Usage: winvm.sh create | install | start | stop | running | wait-ssh | ssh [command…] | screen <file.png> | key <key>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${OS_SWITCH_VM_DIR:-$HOME/.cache/os-switch-vm}"
DIR="$BASE/win"
ISO_URL='https://go.microsoft.com/fwlink/?linkid=2334167&clcid=0x409&culture=en-us&country=us' # 90-day evaluation
SSHD_URL=https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip
OVMF=/usr/share/edk2/x64
PORT=2223
SSH=(ssh -q -i "$BASE/id" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5 test@127.0.0.1)

monitor() { echo "$*" | socat - "UNIX-CONNECT:$DIR/monitor.sock" >/dev/null; }
running() { [ -f "$DIR/pid" ] && kill -0 "$(cat "$DIR/pid")" 2>/dev/null; }

create() {
    mkdir -p "$DIR"
    [ -f "$DIR/win11-eval.iso" ] || curl -sSL -o "$DIR/win11-eval.iso" "$ISO_URL"
    [ -f "$DIR/OpenSSH-Win64.zip" ] || curl -sSL -o "$DIR/OpenSSH-Win64.zip" "$SSHD_URL"
    [ -f "$BASE/id" ] || ssh-keygen -q -t ed25519 -N '' -f "$BASE/id"
    qemu-img create -q -f qcow2 "$DIR/win.qcow2" 64G
    cp "$OVMF/OVMF_VARS.4m.fd" "$DIR/vars.fd"
    local media; media=$(mktemp -d)
    cp "$HERE/autounattend.xml" "$HERE/first-logon.ps1" "$DIR/OpenSSH-Win64.zip" "$BASE/id.pub" "$media/"
    genisoimage -quiet -output "$DIR/unattend.iso" -volid UNATTEND -joliet -rock "$media"
    rm -rf "$media"
}

# qemu [extra arguments…]
qemu() {
    local linux=()
    # The Linux disk, if the Linux test VM exists and is not using it.
    if [ -z "${NO_LINUX_DISK:-}" ] && [ -f "$BASE/disk.qcow2" ] && ! { [ -f "$BASE/pid" ] && kill -0 "$(cat "$BASE/pid")" 2>/dev/null; }; then
        linux=(-drive "if=none,id=linux,format=qcow2,file=$BASE/disk.qcow2" -device "ide-hd,drive=linux,bus=ide.3,serial=OSSWITCH-LINUX")
    fi
    qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 8192 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF/OVMF_CODE.4m.fd" \
        -drive if=pflash,format=raw,file="$DIR/vars.fd" \
        -drive if=none,id=win,format=qcow2,file="$DIR/win.qcow2" -device ide-hd,drive=win,bus=ide.0,serial=OSSWITCH-WIN \
        "${linux[@]}" \
        -nic user,model=e1000e,hostfwd=tcp:127.0.0.1:"$PORT"-:22 \
        -vga std -display none -rtc base=localtime \
        -monitor unix:"$DIR/monitor.sock",server,nowait \
        -pidfile "$DIR/pid" -daemonize "$@"
}

install() {
    # Without the Linux disk: Windows Setup must not see anything but its own.
    NO_LINUX_DISK=1 qemu -drive if=none,id=cd,media=cdrom,readonly=on,file="$DIR/win11-eval.iso" -device ide-cd,drive=cd,bus=ide.1,bootindex=0 \
        -drive if=none,id=un,media=cdrom,readonly=on,file="$DIR/unattend.iso" -device ide-cd,drive=un,bus=ide.2
    # "Press any key to boot from CD or DVD…"
    for _ in $(seq 6); do monitor sendkey ret; sleep 1; done
}

# Type a string on the VM's keyboard (US layout).
type_text() {
    local i c k
    for ((i = 0; i < ${#1}; i++)); do
        c=${1:i:1}
        case "$c" in
            [a-z0-9]) k=$c ;;
            [A-Z]) k="shift-$(echo "$c" | tr "[:upper:]" "[:lower:]")" ;;
            ' ') k=spc ;; '-') k=minus ;; '.') k="dot" ;; '/') k=slash ;;
            ':') k=shift-semicolon ;; '_') k=shift-minus ;; '=') k=equal ;; '"') k=shift-apostrophe ;;
            *) echo "winvm: cannot type '$c'" >&2; return 1 ;;
        esac
        monitor sendkey "$k"
        sleep 0.05
    done
}

wait_ssh() {
    for _ in $(seq "${1:-90}"); do
        "${SSH[@]}" exit 2>/dev/null && return 0
        sleep 10
    done
    echo "winvm: no SSH" >&2
    return 1
}

case "${1:-}" in
    create) create ;;
    install) install ;;
    start) qemu ;;
    stop) running && kill "$(cat "$DIR/pid")"; rm -f "$DIR/pid" ;;
    running) running ;;
    wait-ssh) wait_ssh "${2:-90}" ;;
    ssh) shift; "${SSH[@]}" "$@" ;;
    key) monitor sendkey "$2" ;;
    type) type_text "$2" ;;
    run) monitor sendkey meta_l-r; sleep 2; type_text "$2"; monitor sendkey ret ;;
    screen) monitor screendump "$DIR/screen.ppm"; sleep 1; magick "$DIR/screen.ppm" "$2" 2>/dev/null || cp "$DIR/screen.ppm" "$2" ;;
    *) echo "usage: winvm.sh create|install|start|stop|running|wait-ssh [tries]|ssh [command…]|key <key>|type <text>|run <command>|screen <file>" >&2; exit 2 ;;
esac
