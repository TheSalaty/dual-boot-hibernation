#!/usr/bin/env bash
# A throwaway QEMU/UEFI machine for testing os-switch without a real reboot.
# Usage: vm.sh create | start | stop | ssh [command…] | wait-ssh | serial
set -euo pipefail

DIR="${OS_SWITCH_VM_DIR:-$HOME/.cache/os-switch-vm}"
IMAGE_URL=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
OVMF=/usr/share/edk2/x64
PORT=2222
SSH=(ssh -q -i "$DIR/id" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5 arch@127.0.0.1)

create() {
    mkdir -p "$DIR"
    [ -f "$DIR/base.qcow2" ] || curl -sS -o "$DIR/base.qcow2" "$IMAGE_URL"
    [ -f "$DIR/id" ] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/id"
    qemu-img create -q -f qcow2 -b "$DIR/base.qcow2" -F qcow2 "$DIR/disk.qcow2" 12G
    cp "$OVMF/OVMF_VARS.4m.fd" "$DIR/vars.fd"
    local seed; seed=$(mktemp -d)
    printf 'instance-id: os-switch-vm\nlocal-hostname: osvm\n' >"$seed/meta-data"
    cat >"$seed/user-data" <<USERDATA
#cloud-config
users:
  - name: arch
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$DIR/id.pub")
USERDATA
    genisoimage -quiet -output "$DIR/seed.iso" -volid cidata -joliet -rock "$seed/user-data" "$seed/meta-data"
    rm -rf "$seed"
}

start() {
    qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 2 -m 2048 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF/OVMF_CODE.4m.fd" \
        -drive if=pflash,format=raw,file="$DIR/vars.fd" \
        -drive if=virtio,format=qcow2,file="$DIR/disk.qcow2" \
        -drive if=virtio,format=raw,readonly=on,file="$DIR/seed.iso" \
        -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:"$PORT"-:22 \
        -display none -serial file:"$DIR/serial.log" -action watchdog=none \
        -monitor unix:"$DIR/monitor.sock",server,nowait \
        -pidfile "$DIR/pid" -daemonize
}

running() { [ -f "$DIR/pid" ] && kill -0 "$(cat "$DIR/pid")" 2>/dev/null; }

stop() {
    running && kill "$(cat "$DIR/pid")"
    rm -f "$DIR/pid"
}

wait_ssh() {
    for _ in $(seq 60); do
        "${SSH[@]}" true 2>/dev/null && return 0
        sleep 2
    done
    echo "vm: no SSH after 120 s" >&2
    return 1
}

case "${1:-}" in
    create) create ;;
    start) start ;;
    stop) stop ;;
    running) running ;;
    wait-ssh) wait_ssh ;;
    ssh) shift; "${SSH[@]}" "$@" ;;
    serial) cat "$DIR/serial.log" ;;
    *) echo "usage: vm.sh create|start|stop|running|wait-ssh|ssh [command…]|serial" >&2; exit 2 ;;
esac
