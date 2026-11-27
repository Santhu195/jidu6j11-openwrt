#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:?usage: verify-netifd-packet-steering.sh <packet-steering.uc> <wlan-hotplug> <netifd-Makefile>}"
HOTPLUG="${2:?missing wlan hotplug script path}"
MAKEFILE="${3:?missing netifd Makefile path}"

[ -s "$SCRIPT" ] || { echo "::error::Missing packet-steering source: $SCRIPT"; exit 1; }
[ -x "$HOTPLUG" ] || { echo "::error::Missing or non-executable WLAN hotplug script: $HOTPLUG"; exit 1; }
[ -s "$MAKEFILE" ] || { echo "::error::Missing netifd Makefile: $MAKEFILE"; exit 1; }

require_text() {
  local file="$1" needle="$2" description="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "::error::netifd preflight: missing $description in $file"
    exit 1
  fi
}

# Keep PCI MSI discovery and the Qualcomm PPE ethernet-dma child fallback.
require_text "$SCRIPT" 'glob(`${path}/msi_irqs/*`)' "existing PCI MSI IRQ discovery"
require_text "$SCRIPT" 'node = `${node}/ethernet-dma`;' "EDMA child-node discovery"
require_text "$SCRIPT" 'interrupt-names' "EDMA interrupt-name parsing"
require_text "$SCRIPT" 'match(irq_names[off / 12] ?? "", /^rxdesc_/)' "RX descriptor-only IRQ selection"
require_text "$SCRIPT" 'effective_affinity_list' "effective IRQ affinity lookup"
require_text "$SCRIPT" 'let parent;' "inherited interrupt-parent lookup"
parent_count="$(grep -Fc 'let parent;' "$SCRIPT" || true)"
if [ "$parent_count" -ne 1 ]; then
  echo "::error::netifd preflight: expected exactly one parent declaration, found $parent_count"
  exit 1
fi

# Preserve upstream PR #26222 for Ethernet and non-RSS devices, while
# testing PR #26655's separate Wi-Fi RSS policy on its own branch.
require_text "$SCRIPT" 'let hw_spread = !length(dev.tasks) &&' "upstream hardware-spread detection"
require_text "$SCRIPT" '(dev.rss || length(dev.rx_queues) >= length(cpus))' "hardware RSS / queue-spread detection"
require_text "$SCRIPT" 'else if (hw_spread && dev.rss)' "wireless RSS RPS all-CPU override"
require_text "$SCRIPT" 'else if (!hw_spread)' "RPS fallback for partially spread devices"

rps_line="$(grep -n -F 'else if (rps_cpus)' "$SCRIPT" | head -n1 | cut -d: -f1)"
rss_line="$(grep -n -F 'else if (hw_spread && dev.rss)' "$SCRIPT" | head -n1 | cut -d: -f1)"
default_line="$(grep -n -F 'else if (!hw_spread)' "$SCRIPT" | head -n1 | cut -d: -f1)"
if [ -z "$rps_line" ] || [ -z "$rss_line" ] || [ -z "$default_line" ] ||
   [ "$rps_line" -ge "$rss_line" ] || [ "$rss_line" -ge "$default_line" ]; then
  echo "::error::netifd preflight: explicit RPS, wireless RSS and partial-spread fallback order is wrong"
  exit 1
fi
if ! grep -A5 -F 'else if (hw_spread && dev.rss)' "$SCRIPT" | grep -Fq 'cpu = -1;'; then
  echo "::error::netifd preflight: wireless RSS branch does not select all CPUs"
  exit 1
fi
require_text "$SCRIPT" 'if (disable || cpu == null)' "null CPU mask conversion to zero"
require_text "$SCRIPT" 'else if (cpu < 0)' "explicit all-CPU override preservation"

# The wlan hotplug hook must only schedule a delayed service reload for wlan adds.
for token in '[ "$ACTION" = add ]' '[ "$DEVTYPE" = wlan ]' 'sleep 3' '/etc/init.d/packet_steering reload'; do
  if ! grep -Fq -- "$token" "$HOTPLUG"; then
    echo "::error::netifd preflight: WLAN hotplug hook missing $token"
    exit 1
  fi
done
require_text "$MAKEFILE" 'PKG_RELEASE:=3' "netifd package release bump"

# Source-policy fixture: when hardware RSS/IRQ spread already spans all
# CPUs, keep RPS unset (mask 0) for both Wi-Fi and EDMA RXDESC.
python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
for token in (
    "let hw_spread = !length(dev.tasks) &&",
    "(dev.rss || length(dev.rx_queues) >= length(cpus))",
    "else if (rps_cpus)",
    "else if (hw_spread && dev.rss)",
    "else if (!hw_spread)",
    "if (disable || cpu == null)",
    "else if (cpu < 0)",
):
    assert token in source, f"missing packet-steering policy token: {token}"
assert "else if (hw_spread && dev.rss)" in source

def rps_mask(*, hw_spread: bool, is_rss: bool = False,
             explicit_all_cpus: bool = False, rps_cpus=None) -> str:
    if explicit_all_cpus:
        cpu = -1
    elif rps_cpus is not None:
        cpu = rps_cpus
    elif hw_spread and is_rss:
        cpu = -1
    elif not hw_spread:
        cpu = 1
    else:
        cpu = None
    if cpu is None:
        return "0"
    if isinstance(cpu, int) and cpu < 0:
        return "f"
    if isinstance(cpu, list):
        return "".join(format(1 << n, "x") for n in cpu)
    return format(1 << cpu, "x")

assert rps_mask(hw_spread=True, is_rss=True) == "f"    # Wi-Fi RSS: stack on all CPUs
assert rps_mask(hw_spread=True, is_rss=False) == "0"   # EDMA RXDESC: hardware already spreads
assert rps_mask(hw_spread=False, is_rss=True) == "2"   # partial IRQ spread: other CPU
assert rps_mask(hw_spread=True, explicit_all_cpus=True) == "f"
assert rps_mask(hw_spread=True, is_rss=True, rps_cpus=2) == "4"
print("RSS/RPS policy fixture passed: Wi-Fi RSS=f; EDMA RXDESC=0; partial spread=2")
PY

echo "::notice::netifd preflight passed: EDMA RXDESC discovery, upstream hardware-RSS policy and WLAN hotplug reload"
