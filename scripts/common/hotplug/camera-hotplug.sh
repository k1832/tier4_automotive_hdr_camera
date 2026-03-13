#!/bin/bash
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 board L4T-revision overlay-args..."
    echo "  board = orin-devkit, roscube, roscube-orin xavier-devkit"
    echo "  L4T-revision = R32.5.1, R32.5.2, R32.6.1, R35.1 ..."
    exit 1
fi

BOARD=$1
L4T_REVISION=$2
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GENERATOR="$REPO_ROOT/tools/dts_generator/make_overlay_dts_${BOARD}.py"
DEDUP="$REPO_ROOT/tools/dts_generator/dedup_overlay_dts.py"
OVERLAY_DIR="$SCRIPT_DIR/overlay"
BASE_DTSI="$REPO_ROOT/tools/dts_generator/dtsi/tegra-camera-base-r36.dtsi"

set -eux

mkdir -p "$OVERLAY_DIR"
cd "$OVERLAY_DIR"
rm -f *.dts *.dtbo

# Step 1: Generate DTS source
"$GENERATOR" "$L4T_REVISION" ${@:3}

# Step 2: Unload sensor driver and remove previous overlays
sudo modprobe -r tier4_imx728 || true
sudo rmdir /sys/kernel/config/device-tree/overlays/camera/ || true
sudo rmdir /sys/kernel/config/device-tree/overlays/camera-base/ || true

# Step 3: If the base DTB lacks camera pipeline nodes (VI ports, NVCSI
# channels, camera-platform), apply the base camera dtsi as a separate
# overlay first.  This is needed for flash configs that don't include
# tegra234-orin-agx-cti-csi.dtsi (e.g. "base").  Without this, later
# fragments that use target-path to reference these nodes would fail
# because the kernel resolves all target-path values against the
# unmodified base tree before applying any overlay fragments.
if [ ! -d /proc/device-tree/tegra-capture-vi/ports ] && [ -f "$BASE_DTSI" ]; then
    BASE_TMP=$(mktemp -d)
    (echo '/dts-v1/; /plugin/;'; cat "$BASE_DTSI") > "$BASE_TMP/base.dts"
    sudo dtc -O dtb -o "$BASE_TMP/base.dtbo" -@ "$BASE_TMP/base.dts"
    sudo mkdir -p /sys/kernel/config/device-tree/overlays/camera-base/
    sudo cp "$BASE_TMP/base.dtbo" /sys/kernel/config/device-tree/overlays/camera-base/dtbo
    echo 1 | sudo tee /sys/kernel/config/device-tree/overlays/camera-base/status
    rm -rf "$BASE_TMP"
fi

# Step 4: Dedup labels and compile.  This MUST run after the base overlay
# (step 3) so that dedup sees camera labels (vi_port0, csi_chan0, etc.)
# in /proc/device-tree/__symbols__/ and strips them from the overlay DTS.
# Without this ordering, dedup would find nothing to strip, and the camera
# overlay would carry duplicate phandle definitions that trigger the
# EINVAL check in overlay.c:add_changeset_node() (see §5 in the analysis).
sudo python3 "$DEDUP" --in-place -v *.dts
sudo dtc -O dtb -o target.dtbo -@ $(ls *.dts)

# Step 5: Apply the camera overlay
sudo mkdir -p /sys/kernel/config/device-tree/overlays/camera/
sudo cp target.dtbo /sys/kernel/config/device-tree/overlays/camera/dtbo
echo 1 | sudo tee /sys/kernel/config/device-tree/overlays/camera/status

# Step 6: Reload sensor driver
sudo modprobe tier4-imx728
