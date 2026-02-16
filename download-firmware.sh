#!/bin/bash

# Took here - https://github.com/lchojnack/zmk-config/blob/totem-dongle/download-firmware.sh
# Script to download firmware from latest GitHub Actions run
# Usage: ./download-firmware.sh [branch]

set -e

REPO="just-alt/zmk-config-totem"
BRANCH="${1:-main}"
OUTPUT_DIR="firmware"

echo "Fetching latest workflow run for branch: $BRANCH"

# Check if gh CLI is installed
if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is not installed."
  echo "Install it from: https://cli.github.com/"
  exit 1
fi

# Get the latest successful workflow run for the branch
RUN_ID=$(gh run list \
  --repo "$REPO" \
  --branch "$BRANCH" \
  --workflow build.yml \
  --status success \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')

if [ -z "$RUN_ID" ]; then
  echo "Error: No successful workflow runs found for branch $BRANCH"
  exit 1
fi

echo "Found workflow run: $RUN_ID"
echo "Downloading artifacts..."

# Clean and create output directory
if [ -d "$OUTPUT_DIR" ]; then
  echo "Cleaning existing firmware directory..."
  rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

# Download all artifacts from the run
gh run download "$RUN_ID" \
  --repo "$REPO" \
  --dir "$OUTPUT_DIR"

echo ""
echo "✓ Firmware downloaded successfully to: $OUTPUT_DIR/"
echo ""
echo "Contents:"
ls -lh "$OUTPUT_DIR"
echo ""
echo "To flash firmware, use: ./flash-firmware.sh [dongle|left|right|reset]"
