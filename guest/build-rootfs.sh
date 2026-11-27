#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${FIRN_HOME:-$HOME/.firn}/images"
STATE_DIR="${FIRN_HOME:-$HOME/.firn}"
mkdir -p "$OUT_DIR" "$STATE_DIR/run"

echo "[firn-rootfs] compiling firn-guestd (linux/arm64)..."
(
  cd "$SCRIPT_DIR/firn-guestd"
  mise exec go@1.27.4 -- env CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -ldflags="-s -w" -o "$SCRIPT_DIR/firn-guestd-bin" .
)
chmod 755 "$SCRIPT_DIR/firn-guestd-bin"

# Pick an available Docker context to build the Alpine ext4 image without requiring privileged mode.
DOCKER_ARGS=()
if [ -n "${BUILD_DOCKER_CONTEXT:-}" ]; then
  DOCKER_ARGS=(--context "$BUILD_DOCKER_CONTEXT")
elif docker --context firn info >/dev/null 2>&1; then
  DOCKER_ARGS=(--context firn)
elif docker info >/dev/null 2>&1; then
  DOCKER_ARGS=()
else
  echo "[firn-rootfs] no running Docker builder context found" >&2
  exit 1
fi

echo "[firn-rootfs] building Alpine 3.21 rootfs, kernel Image, and initramfs via Docker (${DOCKER_ARGS[*]:-default})..."
docker "${DOCKER_ARGS[@]}" run --rm -i \
  -v "$SCRIPT_DIR:/work:ro" \
  -v "$OUT_DIR:/out" \
  alpine:3.21 sh -euxo pipefail -c '
    mkdir -p /rootfs /tmp/work
    apk add --no-cache -q e2fsprogs python3 >/dev/null

    mkdir -p /rootfs/etc/apk
    cp /etc/apk/repositories /rootfs/etc/apk/repositories
    cp -a /etc/apk/keys /rootfs/etc/apk/keys
    apk --root /rootfs --initdb --no-cache -q add \
      alpine-base linux-virt mkinitfs docker docker-cli-compose \
      e2fsprogs iptables ip6tables ca-certificates iproute2 kmod \
      busybox-extras curl bash procps-ng util-linux-misc

    python3 - <<'\''PYEOF'\''
import gzip, struct
from pathlib import Path
raw = Path("/rootfs/boot/vmlinuz-virt").read_bytes()
if raw[4:8] != b"zimg":
    Path("/out/vmlinux.Image").write_bytes(raw)
else:
    off, size = struct.unpack("<II", raw[8:16])
    comp = raw[24:28].rstrip(b"\x00")
    payload = raw[off:off + size]
    if comp != b"gzip":
        raise RuntimeError(f"Unsupported kernel zimg compression: {comp!r}")
    Path("/out/vmlinux.Image").write_bytes(gzip.decompress(payload))
print("kernel Image bytes:", Path("/out/vmlinux.Image").stat().st_size)
PYEOF

    KVER="$(basename /rootfs/lib/modules/*)"
    cat >/rootfs/etc/mkinitfs/mkinitfs.conf <<EOF
features="base virtio ext4"
EOF
    chroot /rootfs /sbin/mkinitfs -c /etc/mkinitfs/mkinitfs.conf -o /boot/initramfs-virt "$KVER"
    cp /rootfs/boot/initramfs-virt /out/initramfs.img

    install -m 0755 /work/init /rootfs/sbin/init
    install -m 0755 /work/firn-guestd-bin /rootfs/usr/local/bin/firn-guestd
    mkdir -p /rootfs/etc/docker /rootfs/var/lib/firn /rootfs/var/lib/docker /rootfs/mnt/rosetta /rootfs/run/firn /rootfs/etc/firn /rootfs/etc/udhcpc
    cat >/rootfs/etc/docker/daemon.json <<'\''EOF'\''
{
  "storage-driver": "overlay2",
  "bip": "10.87.0.1/24",
  "dns": ["10.87.0.1"],
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-address-pools": [
    { "base": "10.88.0.0/16", "size": 24 }
  ]
}
EOF

    rm -f /out/rootfs.ext4.tmp
    truncate -s 2G /out/rootfs.ext4.tmp
    mke2fs -t ext4 -d /rootfs -L firn-root /out/rootfs.ext4.tmp >/dev/null
    mv /out/rootfs.ext4.tmp /out/rootfs.ext4
  '

DATA_DISK="$STATE_DIR/data.ext4"
if [ ! -f "$DATA_DISK" ]; then
  echo "[firn-rootfs] creating sparse 120 GiB data disk at $DATA_DISK..."
  truncate -s 120G "$DATA_DISK"
fi

echo "[firn-rootfs] done:"
ls -lh "$OUT_DIR/vmlinux.Image" "$OUT_DIR/initramfs.img" "$OUT_DIR/rootfs.ext4" "$DATA_DISK"
