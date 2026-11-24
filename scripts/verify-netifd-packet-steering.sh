#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:?usage: verify-netifd-packet-steering.sh <packet-steering.uc>}"

[ -s "$SCRIPT" ] || { echo "::error::Missing packet-steering source: $SCRIPT"; exit 1; }

require_text() {
  local needle="$1" description="$2"
  if ! grep -Fq -- "$needle" "$SCRIPT"; then
    echo "::error::netifd preflight: missing $description"
    exit 1
  fi
}

# Keep the existing PCI MSI path and add the Qualcomm PPE child-node fallback.
require_text 'glob(`${path}/msi_irqs/*`)' "existing PCI MSI IRQ discovery"
require_text 'node = `${node}/ethernet-dma`;' "EDMA child-node discovery"
require_text 'interrupt-names' "EDMA interrupt-name parsing"
require_text 'match(irq_names[off / 12] ?? "", /^rxdesc_/)' "RX descriptor-only IRQ selection"
require_text 'effective_affinity_list' "effective IRQ affinity lookup"

echo "::notice::netifd preflight passed: EDMA child RXDESC IRQ discovery is present"
