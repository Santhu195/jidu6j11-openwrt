#!/usr/bin/env bash
# Clone OpenWrt, merge the device-support PR, apply patches, set up feeds and .config.
# CI cache validation rerun: keep both branch builds exercising the same cache layout.
# Run from anywhere; works relative to the repo root.
# Env: OPENWRT_REPO, OPENWRT_BRANCH, OPENWRT_COMMIT, PR_NUMBER, TARGET, SUBTARGET, EXPECTED_DEVICES, PACKAGES_COMMIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
OPENWRT_BRANCH="${OPENWRT_BRANCH:-main}"
OPENWRT_COMMIT="${OPENWRT_COMMIT:-}"
PR_NUMBER="${PR_NUMBER:-}"
IWINFO_PRS="${IWINFO_PRS:-}"
PACKAGES_COMMIT="${PACKAGES_COMMIT:-}"
TARGET="${TARGET:-qualcommbe}"
SUBTARGET="${SUBTARGET:-ipq95xx}"

git config --global user.name "ci"
git config --global user.email "ci@localhost"
shopt -s nullglob

# Lint custom ath11k patch hunks before cloning feeds or compiling anything.
python3 "$ROOT/scripts/verify-patch-series.py" "$ROOT/patches/ath11k"

echo "::group::Clone OpenWrt"
rm -rf openwrt
git clone --branch "$OPENWRT_BRANCH" "$OPENWRT_REPO" openwrt
cd openwrt
if [ -n "$OPENWRT_COMMIT" ]; then
  echo "Checking out requested OpenWrt commit: $OPENWRT_COMMIT"
  git checkout --detach "$OPENWRT_COMMIT"
fi
UPSTREAM_SHA="$(git rev-parse HEAD)"
if [ -n "$OPENWRT_COMMIT" ] && [ "$UPSTREAM_SHA" != "$OPENWRT_COMMIT" ]; then
  echo "::error::OpenWrt checkout mismatch: expected $OPENWRT_COMMIT, got $UPSTREAM_SHA"
  exit 1
fi
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

  # The local BDF overlay changes the generated ipq-wifi package payload.
  # Bump its release so distinct board-data contents never share a version.
  IPQ_WIFI_MAKEFILE="package/firmware/ipq-wifi/Makefile"
  if ! grep -qx 'PKG_RELEASE:=1' "$IPQ_WIFI_MAKEFILE"; then
    echo "::error::Unexpected ipq-wifi PKG_RELEASE; review the local BDF package version bump"
    exit 1
  fi
  sed -i 's/^PKG_RELEASE:=1$/PKG_RELEASE:=2/' "$IPQ_WIFI_MAKEFILE"
  if ! grep -qx 'PKG_RELEASE:=2' "$IPQ_WIFI_MAKEFILE"; then
    echo "::error::Failed to bump ipq-wifi PKG_RELEASE for local BDF data"
    exit 1
  fi
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

mkdir -p "$ROOT/cache/dl" "$ROOT/cache/ccache" "$ROOT/cache/npm"
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
  npm ci --prefer-offline --cache "$ROOT/cache/npm"
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

# OpenWrt's CCACHE option depends on DEVEL. Without CONFIG_DEVEL, make defconfig
# silently removes CONFIG_CCACHE and the build runs without compiler caching.
cat >> .config <<'EOF'
CONFIG_DEVEL=y
CONFIG_CCACHE=y
CONFIG_VERSION_DIST="OpenWrt (unofficial)"
EOF

make defconfig

# Fail before source compilation if Kconfig drops either required cache option.
for symbol in CONFIG_DEVEL CONFIG_CCACHE; do
  if ! grep -qx "${symbol}=y" .config; then
    echo "::error::${symbol} was not retained by make defconfig; compiler caching would be disabled"
    exit 1
  fi
done

if [ -n "${EXPECTED_DEVICES:-}" ]; then
  n=$(grep -cE "^CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_.*=y" .config || true)
  if [ "$n" -ne "$EXPECTED_DEVICES" ]; then
    echo "::error::Expected $EXPECTED_DEVICES device profiles enabled, found $n"
    exit 1
  fi
fi

echo "::endgroup::"

# Validate the JIDU6611-specific calibration and wireless driver chain before compiling.
IMAGE_MK="target/linux/${TARGET}/image/${SUBTARGET}.mk"
JIDU_DTS="target/linux/qualcommbe/dts/ipq9554-jiorouter-ax6000-jidu6611.dts"
JIDU_COMMON_DTS="target/linux/qualcommbe/dts/ipq9554-jiorouter-ax6000-jidu6j11.dtsi"
BDF_NAME="board-jiorouter_ax6000-jidu6j11.ipq9574"
QCN_BDF_NAME="board-jiorouter_ax6000-jidu6j11.qcn9074"

for path in "$IMAGE_MK" "$JIDU_DTS" "$JIDU_COMMON_DTS" \
            "package/kernel/mac80211/ath.mk" \
            "package/kernel/linux/modules/netsupport.mk" \
            "package/firmware/ipq-wifi/Makefile"; do
  if [ ! -s "$path" ]; then
    echo "::error::Required JIDU build source is missing: $path"
    exit 1
  fi
done

for pkg in kmod-ath11k-ahb kmod-ath11k-pci ath11k-firmware-ipq9574 \
           ath11k-firmware-qcn9074 ipq-wifi-jiorouter_ax6000-jidu6j11; do
  if ! grep -Fq "$pkg" "$IMAGE_MK"; then
    echo "::error::JIDU image profile is missing required wireless component: $pkg"
    exit 1
  fi
done

if [ "$(grep -Fc 'qcom,ath11k-calibration-variant = "JIDU6611";' "$JIDU_DTS")" -ne 2 ] ||
   ! grep -Fq 'compatible = "jiorouter,ax6000-jidu6611"' "$JIDU_DTS"; then
  echo "::error::JIDU6611 DTS compatibility or both radio calibration variants are missing"
  exit 1
fi

for item in 'label = "0:ART";' 'label = "0:BDF";' 'cal_ahb:' 'cal_pci:'; do
  if ! grep -Fq "$item" "$JIDU_COMMON_DTS"; then
    echo "::error::JIDU common DTS is missing required calibration/partition item: $item"
    exit 1
  fi
done

if [ ! -s "$ROOT/bdf/$BDF_NAME" ] ||
   [ ! -s "package/firmware/ipq-wifi/src/$BDF_NAME" ] ||
   ! grep -Fq 'jiorouter_ax6000-jidu6j11' package/firmware/ipq-wifi/Makefile; then
  echo "::error::JIDU IPQ9574 board data is missing or not registered in ipq-wifi"
  exit 1
fi

if [ ! -s "$ROOT/bdf/$QCN_BDF_NAME" ] ||
   [ ! -s "package/firmware/ipq-wifi/src/$QCN_BDF_NAME" ] ||
   ! grep -Fq 'qcn9074' package/firmware/ipq-wifi/Makefile; then
  echo "::error::JIDU QCN9074 board data is missing or not supported by ipq-wifi"
  exit 1
fi

# The current JIDU6J11 device-support PR already enables the shared Q6
# reservation used by its integrated WCSS radio; no local duplicate DTS patch
# should be needed.
if ! grep -A2 -F '&q6_region {' "$JIDU_COMMON_DTS" | grep -Fq 'status = "okay";'; then
  echo "::error::JIDU Q6 reserved-memory region is not enabled in the common DTS"
  exit 1
fi

if ! grep -Fq 'DEPENDS+= @PCI_SUPPORT +kmod-qrtr-mhi +kmod-ath11k' package/kernel/mac80211/ath.mk ||
   ! grep -Fq 'DEPENDS:=+kmod-mhi-bus +kmod-qrtr' package/kernel/linux/modules/netsupport.mk; then
  echo "::error::ath11k PCI / QRTR / MHI dependency chain changed; review it before building"
  exit 1
fi

echo "::notice::JIDU6611 DTS, ART calibration cells, BDF, AHB/PCI drivers and MHI dependency chain verified"

# In UCODE mode, wifi-scripts owns /usr/bin/iwinfo and provides the CLI.
# The legacy iwinfo package must not be selected as it would install the same path.
if grep -qx 'CONFIG_WIFI_SCRIPTS_UCODE=y' .config &&
   grep -qx 'CONFIG_PACKAGE_iwinfo=y' .config; then
  echo "::error::iwinfo CLI package conflicts with wifi-scripts UCODE command; keep -iwinfo in extra-packages.txt"
  exit 1
fi

# Fail early if make defconfig silently drops a package required by this router.
REQUIRED_PACKAGES="
adguardhome tailscale untangled-full
etherwake luci-app-wol
kmod-fs-btrfs btrfs-progs
sqm-scripts luci-app-sqm tc-full ip-full
kmod-sched kmod-sched-core kmod-sched-cake kmod-sched-ctinfo
kmod-sched-red kmod-netem kmod-veth kmod-ifb
luci-lib-jsonc lua jq coreutils-sleep
kmod-wireguard kmod-tun
kmod-hwmon-pwmfan kmod-hid kmod-nf-nat6 kmod-ip6tables tcpdump
"
for pkg in $REQUIRED_PACKAGES; do
  if ! grep -qx "CONFIG_PACKAGE_${pkg}=y" .config; then
    echo "::error::Required package was not selected after make defconfig: $pkg"
    exit 1
  fi
done

# Every explicitly requested extra package must survive make defconfig.
while read -r pkg _; do
  case "$pkg" in
    ""|\#*) continue ;;
    -*) continue ;;
  esac
  if ! grep -qx "CONFIG_PACKAGE_${pkg}=y" .config; then
    echo "::error::Extra package was not selected after make defconfig: $pkg"
    exit 1
  fi
done < "$ROOT/config/extra-packages.txt"

for sku in 6111 6411 6611 6711 6811 6911; do
  profile="CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_jiorouter_ax6000-jidu${sku}=y"
  if ! grep -qx "$profile" .config; then
    echo "::error::JIDU SKU profile was not selected: $sku"
    exit 1
  fi
done
echo "::endgroup::"
