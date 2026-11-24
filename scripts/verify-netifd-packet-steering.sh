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
require_text "$SCRIPT" 'glob(\`${path}/msi_irqs/*\`)' "existing PCI MSI IRQ discovery"
require_text "$SCRIPT" 'node = \`${node}/ethernet-dma\`;' "EDMA child-node discovery"
require_text "$SCRIPT" 'interrupt-names' "EDMA interrupt-name parsing"
require_text "$SCRIPT" 'match(irq_names[off / 12] ?? "", /^rxdesc_/)' "RX descriptor-only IRQ selection"
require_text "$SCRIPT" 'effective_affinity_list' "effective IRQ affinity lookup"
require_text "$SCRIPT" 'let parent;' "inherited interrupt-parent lookup"
parent_count="$(grep -Fc 'let parent;' "$SCRIPT" || true)"
if [ "$parent_count" -ne 1 ]; then
  echo "::error::netifd preflight: expected exactly one parent declaration, found $parent_count"
  exit 1
fi

# Hardware RSS Wi-Fi receives RPS mask f only after the existing explicit
# all-CPU and caller-provided mask overrides. Ethernet without dev.rss stays 0
# when EDMA RXDESC interrupts are already spread over every CPU.
require_text "$SCRIPT" 'else if (hw_spread && dev.rss)' "wireless RSS receive steering branch"
require_text "$SCRIPT" 'cpu = -1;' "all-CPU RPS selection for RSS Wi-Fi"
require_text "$SCRIPT" 'else if (cpu < 0)' "negative CPU mask conversion to all CPUs"
require_text "$SCRIPT" 'if (disable || cpu == null)' "null CPU mask conversion to zero"

rps_line="$(grep -n -F 'else if (rps_cpus)' "$SCRIPT" | head -n1 | cut -d: -f1)"
rss_line="$(grep -n -F 'else if (hw_spread && dev.rss)' "$SCRIPT" | head -n1 | cut -d: -f1)"
default_line="$(grep -n -F 'else if (!hw_spread)' "$SCRIPT" | head -n1 | cut -d: -f1)"
if [ -z "$rps_line" ] || [ -z "$rss_line" ] || [ -z "$default_line" ] ||
   [ "$rps_line" -ge "$rss_line" ] || [ "$rss_line" -ge "$default_line" ]; then
  echo "::error::netifd preflight: RSS branch order would override an explicit mask or the existing fallback"
  exit 1
fi

# The wlan hotplug hook must only schedule a delayed service reload for wlan adds.
for token in '[ "$ACTION" = add ]' '[ "$DEVTYPE" = wlan ]' 'sleep 3' '/etc/init.d/packet_steering reload'; do
  if ! grep -Fq -- "$token" "$HOTPLUG"; then
    echo "::error::netifd preflight: WLAN hotplug hook missing $token"
    exit 1
  fi
done
require_text "$MAKEFILE" 'PKG_RELEASE:=3' "netifd package release bump"

# Small logic fixture for the policy branch: Wi-Fi RSS -> f; EDMA Ethernet
# with hw_spread but no dev.rss -> unset CPU -> set_netdev_cpu writes 0.
python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
for token in ("else if (hw_spread && dev.rss)", "cpu = -1;",
              "else if (!hw_spread)", "if (disable || cpu == null)",
              "else if (cpu < 0)"):
    assert token in source, f"missing policy token: {token}"

def rps_mask(*, hw_spread: bool, rss: bool) -> str:
    cpu = None
    if hw_spread and rss:
        cpu = -1
    elif not hw_spread:
        cpu = 1
    if cpu is None:
        return "0"
    if cpu < 0:
        return "f"
    return format(1 << cpu, "x")

assert rps_mask(hw_spread=True, rss=True) == "f"
assert rps_mask(hw_spread=True, rss=False) == "0"
print("RSS/RPS policy fixture passed: WLAN RSS=f; EDMA Ethernet=0")
PY

echo "::notice::netifd preflight passed: EDMA RXDESC detection, wireless RSS RPS and wlan hotplug reload"
