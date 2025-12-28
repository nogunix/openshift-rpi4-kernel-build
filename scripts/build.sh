#!/usr/bin/env bash
set -euo pipefail

: "${KERNEL_REPO:=https://github.com/raspberrypi/linux.git}"
: "${KERNEL_REF:=rpi-6.6.y}"   # 例: rpi-6.6.y。必要に応じて変更
: "${DEFCONFIG:=bcm2711_defconfig}"
: "${JOBS:=2}"

WORKDIR="${WORKDIR:-/work}"
SRC_DIR="${SRC_DIR:-$WORKDIR/src/linux}"
OUT_DIR="${OUT_DIR:-$WORKDIR/out}"
CCACHE_DIR="${CCACHE_DIR:-$WORKDIR/ccache}"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CCACHE_DIR
export PATH="/usr/lib/ccache:${PATH}"

mkdir -p "$OUT_DIR" "$CCACHE_DIR"

echo "==> Fetch kernel source"
if [ ! -d "$SRC_DIR/.git" ]; then
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --depth=1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$SRC_DIR"
else
  git -C "$SRC_DIR" fetch --depth=1 origin "$KERNEL_REF"
  git -C "$SRC_DIR" checkout -f "$KERNEL_REF"
  git -C "$SRC_DIR" reset --hard "origin/$KERNEL_REF"
fi

echo "==> Configure ($DEFCONFIG)"
make -C "$SRC_DIR" O="$OUT_DIR" "$DEFCONFIG"

echo "==> Build (Image/modules/dtbs)"
make -C "$SRC_DIR" O="$OUT_DIR" -j"${JOBS}" Image modules dtbs

echo "==> Install modules into OUT_DIR/mods"
rm -rf "$OUT_DIR/mods"
make -C "$SRC_DIR" O="$OUT_DIR" INSTALL_MOD_PATH="$OUT_DIR/mods" modules_install

echo "==> Build summary"
ls -lh "$OUT_DIR/arch/arm64/boot/Image"
find "$OUT_DIR/arch/arm64/boot/dts" -maxdepth 2 -name '*rpi-4*.dtb' -o -name '*bcm2711*.dtb' | head -n 20 || true

echo "==> ccache stats"
ccache -s || true

echo "DONE"
