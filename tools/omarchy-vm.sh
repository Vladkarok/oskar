#!/usr/bin/env bash
#
# Omarchy VM for daily-dogfooding the on-screen keyboard.
#
# The nested-session polygon exercises the daemon against a disposable
# compositor, but it cannot reproduce what surrounds a real session: udev
# device churn, systemd user services, sleep/wake, a second keyboard. This VM
# can. It boots with a small zoo of input devices on purpose — the default
# PS/2 keyboard, two USB keyboards and a USB tablet — so the per-device
# layout state that Hyprland keeps is exercised the way a messy real desk is.
#
# First run boots the ISO for the interactive Omarchy install. Later runs
# boot the installed disk. The host repo is mounted read-write over 9p at
# /mnt/osk-src, so the guest builds the daemon from the same tree you edit.
#
#   tools/omarchy-vm.sh              # install mode on first run, disk after
#   tools/omarchy-vm.sh --console    # serial console in this terminal instead
#
# SSH (once the guest has openssh enabled):  ssh -p 2222 <user>@127.0.0.1
# QEMU monitor for runtime hotplug tests:    $VM_DIR/monitor.sock

set -euo pipefail

VM_DIR="${OMARCHY_VM_DIR:-$HOME/.local/share/omarchy-vm}"
ISO="$VM_DIR/omarchy-4.0.2.iso"
ISO_SHA256="2ef8e624aa1bec7e277e28056b8535a6c9373ba48d7ede3f1a01cb6d2373cfb8"
DISK="$VM_DIR/osk-omarchy.qcow2"
VARS="$VM_DIR/OVMF_VARS.fd"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$VM_DIR"

if [[ ! -f "$VARS" ]]; then
    cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$VARS"
fi

want_iso=0
want_console=0
for arg in "$@"; do
    case "$arg" in
        --iso) want_iso=1 ;;
        --console) want_console=1 ;;
    esac
done


install_mode=0
if [[ ! -f "$DISK" ]]; then
    install_mode=1
fi

# The ISO is only fetched when a boot from it is actually requested: the
# download is ~6 GB and a stale copy should not stand between the VM and its
# disk. The checksum runs against the partial file, so a truncated or
# error-page download is deleted instead of ever becoming the ISO.
if (( install_mode || want_iso )); then
    if [[ ! -f "$ISO" ]]; then
        echo "Downloading Omarchy 4.0.2..." >&2
        curl -L --fail --retry 3 -o "$ISO.part" https://iso.omarchy.org/omarchy-4.0.2.iso
        echo "$ISO_SHA256  $ISO.part" | sha256sum -c - || {
            rm -f "$ISO.part"
            echo "ISO checksum mismatch; partial download removed" >&2
            exit 1
        }
        mv "$ISO.part" "$ISO"
    else
        echo "$ISO_SHA256  $ISO" | sha256sum -c - || {
            echo "ISO checksum mismatch" >&2
            exit 1
        }
    fi
fi

if (( install_mode )); then
    qemu-img create -f qcow2 "$DISK" 64G >/dev/null
fi

iso_args=()
if (( install_mode || want_iso )); then
    iso_args=(-cdrom "$ISO")
fi

if (( want_console )); then
    display_args=(-display none -serial mon:stdio)
else
    display_args=(-display gtk,gl=on,grab-on-hover=on -serial file:"$VM_DIR/serial.log")
fi

exec qemu-system-x86_64 \
    -name oskar-vm \
    -machine q35 -accel kvm -cpu host \
    -global ICH9-LPC.disable_s3=0 \
    -smp 6 -m 8G \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",if=none,id=hd,format=qcow2 \
    -device virtio-blk-pci,drive=hd \
    -device virtio-rng-pci \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,id=kbd0 \
    -device usb-kbd,id=kbd1 \
    -device usb-tablet,id=tab0 \
    -fsdev local,id=osk-src,security_model=none,readonly=on,path="$REPO" \
    -device virtio-9p-pci,fsdev=osk-src,mount_tag=osk-src \
    -monitor unix:"$VM_DIR/monitor.sock",server,nowait \
    "${display_args[@]}" \
    "${iso_args[@]}"
