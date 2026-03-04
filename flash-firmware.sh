#!/bin/bash

# Original - https://raw.githubusercontent.com/lchojnack/zmk-config/refs/heads/totem-dongle/flash-firmware.sh
# Script to flash firmware to XIAO-SENSE device
# Usage: ./flash-firmware.sh [dongle|left|right|reset]
#
# Examples:
#   ./flash-firmware.sh dongle    # Flash dongle
#   ./flash-firmware.sh left      # Flash left keyboard half
#   ./flash-firmware.sh right     # Flash right keyboard half
#   ./flash-firmware.sh reset     # Flash settings reset

set -e

OUTPUT_DIR="build"
TARGET="${1:-dongle}"

# Determine firmware file to flash
case "$TARGET" in
dongle)
  echo "Looking for totem_dongle firmware..."
  FIRMWARE=$(find "$OUTPUT_DIR" -name "*totem_dongle*.uf2" -type f | head -n 1)
  DEVICE_NAME="dongle"
  ;;
left)
  echo "Looking for totem_left firmware..."
  FIRMWARE=$(find "$OUTPUT_DIR" -name "*totem_left*.uf2" -type f | head -n 1)
  DEVICE_NAME="left keyboard half"
  ;;
right)
  echo "Looking for totem_right firmware..."
  FIRMWARE=$(find "$OUTPUT_DIR" -name "*totem_right*.uf2" -type f | head -n 1)
  DEVICE_NAME="right keyboard half"
  ;;
reset)
  echo "Looking for settings_reset firmware..."
  FIRMWARE=$(find "$OUTPUT_DIR" -name "*settings_reset*.uf2" -type f | head -n 1)
  DEVICE_NAME="device (settings reset)"
  ;;
*)
  echo "Error: Unknown target '$TARGET'"
  echo "Usage: ./flash-firmware.sh [dongle|left|right|reset]"
  exit 1
  ;;
esac

if [ -z "$FIRMWARE" ]; then
  echo "Error: Firmware for $DEVICE_NAME not found in $OUTPUT_DIR/"
  echo "Run ./download-firmware.sh first to download firmware"
  exit 1
fi

echo "Found: $FIRMWARE"
echo ""
echo "Waiting for XIAO-SENSE device (10s timeout)..."
echo "Put the $DEVICE_NAME in bootloader mode (double-tap reset button)"

# Wait for device to appear (10 second timeout)
MOUNT_POINT=""
TIMEOUT=10
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  for path in /media/$USER/XIAO-SENSE /media/XIAO-SENSE /run/media/$USER/XIAO-SENSE /Volumes/XIAO-SENSE; do
    if [ -d "$path" ]; then
      MOUNT_POINT="$path"
      break 2
    fi
  done
  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -n "."
done
echo ""

if [ -z "$MOUNT_POINT" ]; then
  echo "Error: XIAO-SENSE device not found"
  echo "Please put the $DEVICE_NAME in bootloader mode (double-tap reset button)"
  exit 1
fi

echo "Found device at: $MOUNT_POINT"
echo "Copying firmware to $DEVICE_NAME..."

cp "$FIRMWARE" "$MOUNT_POINT/" 2>/dev/null || true
sync

echo ""
echo "✓ Firmware flashed successfully to $DEVICE_NAME!"
echo "Device will reboot automatically"
