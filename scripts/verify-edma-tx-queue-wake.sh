#!/usr/bin/env bash
set -euo pipefail

EDMA_TX="${1:?usage: verify-edma-tx-queue-wake.sh <prepared-edma_tx.c>}"

[ -s "$EDMA_TX" ] || { echo "::error::Missing prepared EDMA TX source: $EDMA_TX"; exit 1; }

require_text() {
  local needle="$1" description="$2"
  if ! grep -Fq -- "$needle" "$EDMA_TX"; then
    echo "::error::EDMA TX preflight: missing $description"
    exit 1
  fi
}

require_text 'u32 cons_idx, end_idx, data, cpu_id, queue_id;' "completion queue index variable"
require_text 'queue_id = (txcmpl_ring - edma_ctx->txcmpl_rings) %' "completion-ring-to-TX-queue mapping"
require_text 'num_possible_cpus();' "per-CPU TX queue mapping"
require_text 'netdev_get_tx_queue(txcmpl_ring->napi.dev, queue_id);' "waking the queue owned by the completed ring"
require_text '__netif_tx_lock(nq, cpu_id);' "completion CPU lock ownership"
require_text 'netif_tx_wake_queue(nq);' "TX queue wake operation"

if grep -Fq 'netdev_get_tx_queue(txcmpl_ring->napi.dev, cpu_id)' "$EDMA_TX"; then
  echo "::error::EDMA TX preflight: obsolete CPU-indexed queue wake remains"
  exit 1
fi

echo "::notice::EDMA TX preflight passed: completion ring wakes its mapped queue"
