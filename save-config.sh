#!/bin/bash
# Sync build config from sources/poky/build/conf/ and push to GitHub

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/sources/poky/build/conf"
DST="$SCRIPT_DIR/build/conf"

cp "$SRC/local.conf"       "$DST/local.conf"
cp "$SRC/bblayers.conf"    "$DST/bblayers.conf"
cp "$SRC/templateconf.cfg" "$DST/templateconf.cfg"

cd "$SCRIPT_DIR"
git add build/conf/
git diff --cached --stat

read -rp "Enter commit message: " msg
[ -z "$msg" ] && msg="update: sync build/conf from sources/poky/build/conf"

git commit -m "$msg"
git push origin master
