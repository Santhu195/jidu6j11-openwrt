#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: verify-ath11k-patch-application.sh <prepared-backports-dir> <openwrt-tree>}"
TREE="${2:?usage: verify-ath11k-patch-application.sh <prepared-backports-dir> <openwrt-tree>}"
DEST="$TREE/package/kernel/mac80211/patches/ath11k"
REPO_PATCH_DIR="$TREE/../patches/ath11k"

[ -d "$SRC" ] || { echo "::error::Prepared backports source directory missing: $SRC"; exit 1; }
[ -d "$DEST" ] || { echo "::error::OpenWrt ath11k patch directory missing: $DEST"; exit 1; }
[ -d "$REPO_PATCH_DIR" ] || { echo "::error::Repository ath11k patch directory missing: $REPO_PATCH_DIR"; exit 1; }

expected=0
for p in "$REPO_PATCH_DIR"/*.patch; do
  [ -f "$p" ] || continue
  expected=$((expected + 1))
  staged="$DEST/$(basename "$p")"
  if [ ! -s "$staged" ] || ! cmp -s "$p" "$staged"; then
    echo "::error::Custom ath11k patch was not staged byte-identically: $(basename "$p")"
    exit 1
  fi
done
[ "$expected" -gt 0 ] || { echo "::error::No custom ath11k patches found"; exit 1; }

# patch(1) creates a sibling .orig backup for successfully modified files.
# Those backups are expected and do not indicate a rejected hunk; .rej files do.
reject="$(find "$SRC" -type f -name '*.rej' -print -quit)"
if [ -n "$reject" ]; then
  echo "::error::Patch application left a rejected hunk: $reject"
  exit 1
fi

backup_count="$(find "$SRC" -type f -name '*.orig' | wc -l)"
echo "::notice::All $expected custom ath11k patches are staged byte-identically; no rejected hunks remain ($backup_count normal patch backups)"
