#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: verify-ath11k-patches.sh <backports-source-dir>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_text() {
  local file="$1" needle="$2" description="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "::error::Ath11k preflight: missing $description in $file"
    exit 1
  fi
}

require_count() {
  local file="$1" needle="$2" expected="$3" description="$4"
  local actual
  actual="$(grep -Fc -- "$needle" "$file" || true)"
  if [ "$actual" -ne "$expected" ]; then
    echo "::error::Ath11k preflight: expected $expected occurrence(s) of $description in $file, found $actual"
    exit 1
  fi
}

DP="$SRC/drivers/net/wireless/ath/ath11k/dp.c"
DPH="$SRC/drivers/net/wireless/ath/ath11k/dp.h"
DPTX="$SRC/drivers/net/wireless/ath/ath11k/dp_tx.c"
DPTXH="$SRC/drivers/net/wireless/ath/ath11k/dp_tx.h"
DPRX="$SRC/drivers/net/wireless/ath/ath11k/dp_rx.c"
CORE="$SRC/drivers/net/wireless/ath/ath11k/core.c"
MAC="$SRC/drivers/net/wireless/ath/ath11k/mac.c"
MACH="$SRC/drivers/net/wireless/ath/ath11k/mac.h"
MAC_TX="$SRC/net/mac80211/tx.c"
MAC_IH="$SRC/net/mac80211/ieee80211_i.h"
MAC_STATUS="$SRC/net/mac80211/status.c"
PCIC="$SRC/drivers/net/wireless/ath/ath11k/pcic.c"
AHB="$SRC/drivers/net/wireless/ath/ath11k/ahb.c"

for file in "$DP" "$DPH" "$DPTX" "$DPTXH" "$DPRX" "$CORE" "$MAC" "$MACH" "$MAC_TX" "$MAC_IH" "$MAC_STATUS" "$PCIC" "$AHB"; do
  [ -s "$file" ] || { echo "::error::Ath11k preflight: missing patched source $file"; exit 1; }
done

# The ath11k scheduler depends on the mac80211 TXQ scheduling-round fix
# carried by current OpenWrt main as subsystem patch 015.
require_text "$MAC_TX" "local->schedule_open[ac]" "mac80211 TXQ scheduling-round open flag"
require_text "$MAC_IH" "bool schedule_open[IEEE80211_NUM_ACS];" "mac80211 TXQ scheduling-round state"

# Encapsulation-offload frames need the mac80211 AQL station lookup fix.
require_text "$MAC_STATUS" "ieee80211_lookup_ra_sta(sdata, skb, &sta, false)" "AQL station lookup for freed 802.3 frames"

# Airtime queue limits and per-station TX/RX airtime accounting.
require_text "$MAC" "NL80211_EXT_FEATURE_AQL" "AQL feature advertisement"
require_text "$MAC" "NL80211_EXT_FEATURE_AIRTIME_FAIRNESS" "airtime-fairness feature advertisement"
require_text "$MAC" "ath11k_mac_schedule_txq" "driver TXQ scheduler"
require_text "$MAC" ".wake_tx_queue" "custom wake_tx_queue operation"
require_text "$DPRX" "ieee80211_sta_register_airtime(sta, airtime_tid, tx_duration, 0);" "TX airtime accounting call"
require_text "$DPRX" "max_t(u8, common->num_users, 1)" "per-user airtime division for OFDMA/MU-MIMO"
require_count "$DPRX" "u8 airtime_tid;" 1 "airtime_tid declaration"
require_count "$DPRX" "ieee80211_sta_register_airtime(sta, airtime_tid, tx_duration, 0);" 1 "TX airtime accounting call"
require_text "$DPRX" "ieee80211_sta_register_airtime(peer->sta, tid, 0," "RX airtime accounting call"
python3 "$ROOT/scripts/verify-ath11k-source.py" "$DPRX"

# Completion-budget handling and completion-driven TXQ rescheduling.
require_text "$DP" "ath11k_dp_tx_completion_handler(ab, i, budget)" "budgeted TX completion call"
require_text "$DP" "tot_work_done += work_done;" "NAPI completion accounting"
require_text "$DPTX" "while (done < budget" "bounded TX completion loop"
require_text "$DPTX" "ath11k_mac_tx_push_pending" "completion-driven TXQ rescheduling"
require_text "$DPTXH" "int budget);" "budgeted completion declaration"
require_text "$MACH" "void ath11k_mac_tx_push_pending" "TXQ rescheduling prototype"

# TX skb cleanup, RX page-fragment cache, IRQ idempotence and ring-size reduction.
require_text "$CORE" "ath11k_dp_tx_free_pending(ab);" "firmware-recovery TX skb cleanup"
require_text "$DPTX" "void ath11k_dp_tx_free_pending" "pending TX skb cleanup implementation"
require_text "$DPH" "struct page_frag_cache frag_cache;" "private RX page-fragment cache"
require_text "$DPRX" "ath11k_dp_rx_alloc_skb" "private RX skb allocator"
require_text "$PCIC" "irq_set_affinity_and_hint" "PCI IRQ affinity placement"
require_text "$PCIC" "irq_update_affinity_hint" "PCI IRQ affinity cleanup"
require_text "$AHB" "ath11k_ahb_ext_grp_disable(irq_grp);" "idempotent AHB IRQ disable"
require_text "$DPH" "#define DP_RXDMA_BUF_RING_SIZE" "RXDMA buffer ring size"
require_text "$DPH" "#define DP_RXDMA_MONITOR_BUF_RING_SIZE" "monitor buffer ring size"

# The experimental IDR-capacity patch that failed compilation must stay absent.
if grep -Fq "ath11k_dp_tx_idr_remove" "$DPTX"; then
  echo "::error::Ath11k preflight: obsolete experimental IDR helper is present"
  exit 1
fi

echo "::notice::Ath11k preflight passed: airtime accounting, TXQ scheduler, completion budget, recovery cleanup, RX allocation and IRQ patches are present"
