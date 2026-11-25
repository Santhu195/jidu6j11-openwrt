#!/usr/bin/env bash
set -euo pipefail

PPE="${1:?usage: verify-edma-napi.sh <prepared-qualcomm-ppe-source-dir>}"
for f in edma.c edma_cfg_rx.c edma_cfg_tx.c edma_cfg_rx.h edma_cfg_tx.h edma_rx.h edma_tx.h edma_rx.c ppe_port.c; do
  [ -s "$PPE/$f" ] || { echo "::error::EDMA NAPI preflight: missing $PPE/$f"; exit 1; }
done

require_text() {
  local file="$1" needle="$2" description="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "::error::EDMA NAPI preflight: missing $description in $file"
    exit 1
  fi
}

# #25405: the IPQ9574 fallback and both validated module parameters stay <= 64.
require_text "$PPE/edma.c" '.napi_budget_tx = 64,' "safe IPQ9574 TX fallback"
require_text "$PPE/edma.c" 'Tx NAPI budget (default:64, min:16, max:64)' "safe TX budget limits"
require_text "$PPE/edma_cfg_rx.c" 'edma_rx_napi_poll, edma_rx_napi_budget);' "RX NAPI registration uses its validated parameter"
require_text "$PPE/edma_cfg_tx.c" 'edma_tx_napi_poll, edma_tx_napi_budget);' "TX NAPI registration uses its validated parameter"
require_text "$PPE/edma_cfg_rx.h" 'EDMA_RX_NAPI_WORK_DEF' "RX default budget definition"
require_text "$PPE/edma_cfg_tx.h" 'EDMA_TX_NAPI_WORK_DEF' "TX default budget definition"

# #25569: ring state makes NAPI enable/disable/delete idempotent.
require_text "$PPE/edma_rx.h" 'bool napi_enabled;' "RX NAPI enabled state"
require_text "$PPE/edma_tx.h" 'bool napi_enabled;' "TX NAPI enabled state"
require_text "$PPE/edma_cfg_rx.c" 'if (!rxdesc_ring->napi_added || !rxdesc_ring->napi_enabled)' "RX disable guard"
require_text "$PPE/edma_cfg_rx.c" 'if (!rxdesc_ring->napi_added || rxdesc_ring->napi_enabled)' "RX enable guard"
require_text "$PPE/edma_cfg_tx.c" 'if (!txcmpl_ring->napi_added || !txcmpl_ring->napi_enabled)' "TX disable guard"
require_text "$PPE/edma_cfg_tx.c" 'if (!txcmpl_ring->napi_added || txcmpl_ring->napi_enabled)' "TX enable guard"

# Inspect control-flow placement for all three #25569 fixes and NAPI state
# transitions. These are source-level checks, not substitute runtime tests.
python3 - "$PPE" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
def read(name):
    return (root / name).read_text()

def body(text, signature):
    start = text.find(signature)
    assert start >= 0, f"missing function {signature}"
    brace = text.find("{", start)
    assert brace >= 0, f"missing body for {signature}"
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace:i + 1]
    raise AssertionError(f"unterminated function {signature}")

rx = read("edma_cfg_rx.c")
tx = read("edma_cfg_tx.c")
for label, text, name, ring in [
    ("RX", rx, "void edma_cfg_rx_napi_enable(void)", "rxdesc_ring"),
    ("TX", tx, "void edma_cfg_tx_napi_enable", "txcmpl_ring"),
]:
    en = body(text, name)
    assert f"if (!{ring}->napi_added || {ring}->napi_enabled)" in en, f"{label}: enable must skip an already-enabled ring"
    assert f"napi_enable(&{ring}->napi);" in en
    assert f"{ring}->napi_enabled = true;" in en

for label, text, name, ring in [
    ("RX", rx, "void edma_cfg_rx_napi_disable(void)", "rxdesc_ring"),
    ("TX", tx, "void edma_cfg_tx_napi_disable", "txcmpl_ring"),
]:
    dis = body(text, name)
    assert f"if (!{ring}->napi_added || !{ring}->napi_enabled)" in dis, f"{label}: disable must skip an already-disabled ring"
    assert f"napi_disable(&{ring}->napi);" in dis
    assert f"{ring}->napi_enabled = false;" in dis

for label, text, name, ring in [
    ("RX", rx, "void edma_cfg_rx_napi_delete(void)", "rxdesc_ring"),
    ("TX", tx, "void edma_cfg_tx_napi_delete", "txcmpl_ring"),
]:
    dele = body(text, name)
    assert f"if ({ring}->napi_enabled)" in dele, f"{label}: delete must guard napi_disable"
    assert f"napi_disable(&{ring}->napi);" in dele
    assert f"{ring}->napi_enabled = false;" in dele
    assert f"netif_napi_del(&{ring}->napi);" in dele

port = body(read("ppe_port.c"), "int ppe_port_mac_init(")
assert "while (i > 0)" in port, "PPE unwind loop must stop before a negative index"
assert "ppe_port_clock_deinit(&ppe_ports->port[i]);" in port, "failed/previous port clocks must be released"
assert "while (i >= 0)" not in port, "unsafe negative-index unwind loop remains"

rx_body = body(read("edma_rx.c"), "static int edma_rx_reap(")
loop = rx_body.find("while (likely(work_to_do--))")
descriptor = rx_body.find("next_rxdesc_pri = EDMA_RXDESC_PRI_DESC(rxdesc_ring, cons_idx);")
drop_path = rx_body.find("ndev = edma_rx_get_src_dev", loop)

# One read seeds the first skb before the loop. A second read refreshes it
# once per iteration, immediately after the next descriptor is fetched and
# before the unknown-source-port path can free the current skb.
skb_reads = list(__import__("re").finditer(
    r"next_skb\\s*=\\s*\\(struct sk_buff \\*\\)EDMA_RXDESC_OPAQUE_GET\\(next_rxdesc_pri\\);",
    rx_body,
))
assert loop >= 0 and descriptor >= 0 and drop_path >= 0, "missing RX loop/descriptor/source-port path"
assert len(skb_reads) == 2, "expected one initial next_skb seed and one per-iteration refresh"
assert descriptor < skb_reads[0].start() < loop, "initial next_skb must seed the first reap iteration"
loop_descriptor = rx_body.find("next_rxdesc_pri = EDMA_RXDESC_PRI_DESC(rxdesc_ring, cons_idx);", loop)
assert loop < loop_descriptor < skb_reads[1].start() < drop_path, "per-iteration next_skb refresh must follow the next descriptor fetch and precede every drop path"

print("EDMA source checks passed: safe budgets, idempotent NAPI lifecycle, safe port unwind and RX skb advancement")
PY

echo "::notice::EDMA NAPI/reliability preflight passed (source-level checks only)"
