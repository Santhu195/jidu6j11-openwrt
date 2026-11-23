#!/usr/bin/env bash
# Clone OpenWrt, merge the device-support PR, apply patches, set up feeds and .config.
# Run from anywhere; works relative to the repo root.
# Env: OPENWRT_REPO, OPENWRT_BRANCH, PR_NUMBER, TARGET, SUBTARGET, EXPECTED_DEVICES, PACKAGES_COMMIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_BRANCH="${OPENWRT_BRANCH:-main}"
PR_NUMBER="${PR_NUMBER:-}"
IWINFO_PRS="${IWINFO_PRS:-}"
PACKAGES_COMMIT="${PACKAGES_COMMIT:-}"
TARGET="${TARGET:-qualcommbe}"
SUBTARGET="${SUBTARGET:-ipq95xx}"

git config --global user.name "ci"
git config --global user.email "ci@localhost"
shopt -s nullglob

echo "::group::Clone OpenWrt"
rm -rf openwrt
git clone --branch "$OPENWRT_BRANCH" "$OPENWRT_REPO" openwrt
cd openwrt
UPSTREAM_SHA="$(git rev-parse HEAD)"
PR_SHA=""
if [ -n "$PR_NUMBER" ]; then
  git fetch origin "pull/$PR_NUMBER/head"
  PR_SHA="$(git rev-parse FETCH_HEAD)"
  git merge --no-edit FETCH_HEAD
fi
cat > "$ROOT/build-info.env" <<EOF
UPSTREAM_SHA=$UPSTREAM_SHA
PR_NUMBER=$PR_NUMBER
PR_SHA=$PR_SHA
IWINFO_PRS="$IWINFO_PRS"
PACKAGES_COMMIT=$PACKAGES_COMMIT
EOF
echo "::endgroup::"

echo "::group::Apply patches/openwrt"
for p in "$ROOT"/patches/openwrt/*.patch; do
  echo "Applying $p"
  git apply --check "$p"
  git apply "$p"
  git add -A
  git -c user.name="ci" -c user.email="ci@localhost" commit -m "Apply $(basename "$p" .patch)"
done
echo "::endgroup::"

echo "::group::Copy custom BDFs"
if [ -d "$ROOT/bdf" ]; then
  mkdir -p package/firmware/ipq-wifi/src
  cp -v "$ROOT"/bdf/* package/firmware/ipq-wifi/src/
fi
echo "::endgroup::"

echo "::group::Copy ath11k patches"
mkdir -p package/kernel/mac80211/patches/ath11k
for p in "$ROOT"/patches/ath11k/*.patch; do
  dest="package/kernel/mac80211/patches/ath11k/$(basename "$p")"
  if [ -e "$dest" ]; then
    echo "::error::Custom ath11k patch collides with upstream file: $dest"
    exit 1
  fi
  cp -v "$p" package/kernel/mac80211/patches/ath11k/
done
echo "::endgroup::"

echo "::group::Apply open iwinfo PRs"
for n in $IWINFO_PRS; do
  mkdir -p package/network/utils/iwinfo/patches
  echo "Fetching iwinfo PR #$n"
  curl -fsSL --retry 3 "https://github.com/openwrt/iwinfo/pull/$n.patch" \
    -o "package/network/utils/iwinfo/patches/900-iwinfo-pr-$n.patch"
done
echo "::endgroup::"

mkdir -p "$ROOT/cache/dl" "$ROOT/cache/ccache"
ln -sfn "$ROOT/cache/dl" dl
ln -sfn "$ROOT/cache/ccache" .ccache
echo "max_size = 3.0G" > "$ROOT/cache/ccache/ccache.conf"

echo "::group::Feeds"
cp feeds.conf.default feeds.conf
for f in "$ROOT"/feeds.conf.default.d/*; do
  [ -f "$f" ] || continue
  echo "" >> feeds.conf
  cat "$f" >> feeds.conf
done
if [ -n "$PACKAGES_COMMIT" ]; then
  sed -i "s|^src-git packages .*|src-git packages https://git.openwrt.org/feed/packages.git^$PACKAGES_COMMIT|" feeds.conf
fi
./scripts/feeds update -a

for p in "$ROOT"/patches/packages/*.patch; do
  git -C feeds/packages am --3way "$p"
done

./scripts/feeds install -a
echo "::endgroup::"

echo "::group::Build UnTangled 0.1.12 package"
UNTANGLED_DIR="$ROOT/cache/untangled"
rm -rf "$UNTANGLED_DIR"
git clone --depth 1 --branch v0.1.12 https://github.com/bidhata/untangled.git "$UNTANGLED_DIR"
(
  cd "$UNTANGLED_DIR"
  npm ci
  npm run build
)
mkdir -p package/untangled
cp -a "$UNTANGLED_DIR/openwrt/Makefile" package/untangled/
cp -a "$UNTANGLED_DIR/openwrt/files" "$UNTANGLED_DIR/openwrt/files-mesh" package/untangled/
sed -i 's/^PKG_VERSION:=0.1.0$/PKG_VERSION:=0.1.12/' package/untangled/Makefile
mkdir -p package/untangled/files/www/untangled
cp -a "$UNTANGLED_DIR/dist/." package/untangled/files/www/untangled/
echo "::endgroup::"

if [ -d "$ROOT/files" ]; then
  cp -r "$ROOT/files" files
fi

echo "::group::Config"
: > .config
cat "$ROOT/config/base.diffconfig" >> .config
if [ -f "$ROOT/config/extra-packages.txt" ]; then
  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      p = $1
      if (substr(p, 1, 1) == "-") print "# CONFIG_PACKAGE_" substr(p, 2) " is not set"
      else                        print "CONFIG_PACKAGE_" p "=y"
    }
  ' "$ROOT/config/extra-packages.txt" >> .config
fi

cat >> .config <<'EOF'
CONFIG_CCACHE=y
CONFIG_VERSION_DIST="OpenWrt (unofficial)"
EOF

make defconfig

if [ -n "${EXPECTED_DEVICES:-}" ]; then
  n=$(grep -cE "^CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_.*=y" .config || true)
  if [ "$n" -ne "$EXPECTED_DEVICES" ]; then
    echo "::error::Expected $EXPECTED_DEVICES device profiles enabled, found $n"
    exit 1
  fi
fi

# Fail early if make defconfig silently drops a package required by this router.
REQUIRED_PACKAGES="
adguardhome tailscale untangled-full
kmod-fs-btrfs btrfs-progs
sqm-scripts luci-app-sqm tc-full ip-full
kmod-sched kmod-sched-core kmod-sched-cake kmod-sched-ctinfo
kmod-sched-red kmod-netem kmod-veth kmod-ifb
luci-lib-jsonc lua jq coreutils-sleep
kmod-wireguard kmod-tun
kmod-hwmon-pwmfan kmod-hid kmod-nf-nat6 kmod-ip6tables
"
for pkg in $REQUIRED_PACKAGES; do
  if ! grep -qx "CONFIG_PACKAGE_${pkg}=y" .config; then
    echo "::error::Required package was not selected after make defconfig: $pkg"
    exit 1
  fi
done

for sku in 6111 6411 6611 6711 6811 6911; do
  profile="CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_jiorouter_ax6000-jidu${sku}=y"
  if ! grep -qx "$profile" .config; then
    echo "::error::JIDU SKU profile was not selected: $sku"
    exit 1
  fi
done
echo "::endgroup::"
