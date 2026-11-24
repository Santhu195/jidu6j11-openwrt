#!/usr/bin/env bash
set -euo pipefail

EDMA="$1"
if [ -z "$EDMA" ] || [ ! -s "$EDMA" ]; then
  echo "::error::usage: verify-edma-rx-irq-affinity.sh <prepared-edma.c>"
  exit 1
fi

require_text() {
  local needle="$1" description="$2"
  if ! grep -Fq -- "$needle" "$EDMA"; then
    echo "::error::EDMA RX IRQ preflight: missing $description"
    exit 1
  fi
}

require_count() {
  local needle="$1" expected="$2" description="$3" actual
  actual="$(grep -Fc -- "$needle" "$EDMA" || true)"
  if [ "$actual" -ne "$expected" ]; then
    echo "::error::EDMA RX IRQ preflight: expected $expected occurrence(s) of $description, found $actual"
    exit 1
  fi
}

# RX descriptor rings are receive-side work queues. Keep their affinity
# distributed by ring index, and clear the hint on failure and teardown.
require_text 'irq_set_affinity_and_hint(edma_ctx->intr_info.intr_rx[i],' "RX descriptor IRQ affinity assignment"
require_text 'cpumask_of(i % num_possible_cpus())' "ring-to-CPU mapping"
require_text 'irq_update_affinity_hint(edma_ctx->intr_info.intr_rx[i], NULL);' "RX descriptor IRQ affinity-hint cleanup"
require_count 'irq_update_affinity_hint(edma_ctx->intr_info.intr_rx[i], NULL);' 2 "RX descriptor IRQ affinity-hint cleanup"

# Do not pin TX completion IRQs speculatively. The separate TX queue-wakeup
# fix handles completion on a CPU other than the queue owner; avoid adding
# an unbenchmarked IRQ-placement policy.
if grep -Fq 'irq_set_affinity_and_hint(edma_ctx->intr_info.intr_txcmpl' "$EDMA"; then
  echo "::error::EDMA RX IRQ preflight: unexpected forced TX-completion IRQ affinity; review before enabling"
  exit 1
fi

echo "::notice::EDMA RX IRQ preflight passed: RX rings are spread and hints are cleaned up"
