#!/bin/bash
# Downloads the cloudflared ARM 32-bit binary (for RPi3) from Cloudflare's
# official GitHub releases and places it in the recipe's files/ directory.
# Run this ONCE before building the Yocto image.
#
# Usage:  bash scripts/download-cloudflared.sh

set -e

DEST="$(cd "$(dirname "$0")/.." && pwd)/sources/meta-userapp-package/recipes-apps/cloudflared/files/cloudflared"

echo "Fetching latest cloudflared release tag..."
LATEST=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
         | grep '"tag_name"' | cut -d'"' -f4)

if [ -z "$LATEST" ]; then
    echo "ERROR: Could not fetch latest release. Check network connectivity."
    exit 1
fi

echo "Latest version: $LATEST"
URL="https://github.com/cloudflare/cloudflared/releases/download/${LATEST}/cloudflared-linux-arm"

echo "Downloading: $URL"
curl -L --progress-bar -o "$DEST" "$URL"
chmod +x "$DEST"

echo ""
echo "Saved to: $DEST"
echo "SHA256: $(sha256sum "$DEST" | awk '{print $1}')"
echo ""
echo "Done. You can now run: bitbake cloudflared"
