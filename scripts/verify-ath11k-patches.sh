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

require_define_value() {
  local file="$1" symbol="$2" expected="$3" description="$4"
  if ! grep -Eq "^[[:space:]]*#define[[:space:]]+${symbol}[[:space:]]+${expected}([[:space:]]|$)" "$file"; then
    echo "::error::Ath11k preflight: ${description} must be ${expected} in ${file}"
    exit 1
  fi
}

DP="$SRC/drivers/net/wireless/ath/ath11k/dp.c"
DPH="$SRC/drivers/net/wireless/ath/ath11k/dp.h"
DPTX="$SRC/drivers/net/wireless/ath/ath11k/dp_tx.c"
DPTXH="$SRC/drivers/net/wireless/ath/ath11k/dp_tx.h"
DPRX="$SRC/drivers/net/wireless/ath/ath11k/dp_rx.c"
CORE="$SRC/drivers/net/wireless/ath/ath11k/core.c"
COREH="$SRC/drivers/net/wireless/ath/ath11k/core.h"
MAC="$SRC/drivers/net/wireless/ath/ath11k/mac.c"
MACH="$SRC/drivers/net/wireless/ath/ath11k/mac.h"
MAC_TX="$SRC/net/mac80211/tx.c"
MAC_IH="$SRC/net/mac80211/ieee80211_i.h"
MAC_STATUS="$SRC/net/mac80211/status.c"
PCIC="$SRC/drivers/net/wireless/ath/ath11k/pcic.c"
AHB="$SRC/drivers/net/wireless/ath/ath11k/ahb.c"

for file in "$DP" "$DPH" "$DPTX" "$DPTXH" "$DPRX" "$CORE" "$COREH" "$MAC" "$MACH" "$MAC_TX" "$MAC_IH" "$MAC_STATUS" "$PCIC" "$AHB"; do
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

# #25982 exposes firmware PPDU retry counts through nl80211 station statistics.
require_text "$COREH" "u32 tx_retries;" "per-station TX retry counter"
require_text "$DPRX" "arsta->tx_retries +=" "HTT PPDU retry accumulation"
require_text "$MAC" "sinfo->tx_retries = arsta->tx_retries;" "station TX retry export"
require_text "$MAC" "NL80211_STA_INFO_TX_RETRIES" "station TX retry statistics flag"

python3 "$ROOT/scripts/verify-ath11k-source.py" "$DPRX"

# Completion-budget handling and completion-driven TXQ rescheduling.
require_text "$DP" "ath11k_dp_tx_completion_handler(ab, i, budget)" "budgeted TX completion call"
require_text "$DP" "tot_work_done += work_done;" "NAPI completion accounting"
require_text "$DPTX" "while (done < budget" "bounded TX completion loop"
require_text "$DPTX" "ath11k_mac_tx_push_pending" "completion-driven TXQ rescheduling"
require_text "$DPTXH" "int budget);" "budgeted completion declaration"
require_text "$MACH" "void ath11k_mac_tx_push_pending" "TXQ rescheduling prototype"

# TX/RX buffer lifecycle, page-pool allocation, IRQ idempotence and ring-size reduction.
require_text "$CORE" "ath11k_dp_tx_free_pending(ab);" "firmware-recovery TX skb cleanup"
require_text "$DPTX" "void ath11k_dp_tx_free_pending" "pending TX skb cleanup implementation"
require_text "$DPH" "struct page_pool *page_pool;" "dedicated RX page pool"
require_text "$DPRX" "page_pool_dev_alloc_frag" "RX page-pool fragment allocator"
require_text "$DPRX" "page_pool_create(&pp_params)" "per-radio RX page-pool creation"
require_text "$DPH" "struct sk_buff **bufs;" "RX buffer lookup table"
require_text "$DPH" "u32 *free_ids;" "RX buffer free-ID stack"
require_text "$DPRX" "rx_ring->refill_deficit" "RX refill deficit retention"
require_text "$DPRX" "min_t(int, req_entries + rx_ring->refill_deficit" "retry of previously unallocated RX refill buffers"
require_text "$DPRX" "rx_ring->refill_deficit = num_remain;" "RX refill deficit update"
if grep -Fq "ath11k_rx_refill_early" "$DPRX"; then
  echo "::error::Ath11k preflight: obsolete intermediate refill flag survived patch 999z18"
  exit 1
fi
require_text "$DP" "ath11k_dp_service_rx_refill(ab, grp_id);" "RX refill service before budgeted handlers"
require_text "$DPRX" "ATH11K_DP_RX_REFILL_CHUNK" "batched RX refill IDs"
require_text "$DPRX" "skb_set_hash(msdu," "hardware RX flow hash propagation"
require_text "$DPRX" "RX_MSDU_START_INFO2_IP_FIXED_HDR_VALID" "RX checksum verification only after parsed IP header"
require_text "$DPRX" "FIELD_GET(RX_MSDU_DESC_INFO0_MSDU_LENGTH, info0)" "bounded RX page-pool DMA sync length"
require_text "$DPRX" "dp->reo_dst_cont[ring_id]" "RX continuation-chain DMA sync tracking"
require_text "$SRC/drivers/net/wireless/ath/ath11k/hal.c" "ath11k_hal_srng_dst_sync" "batched cached destination-ring DMA sync"
require_text "$SRC/drivers/net/wireless/ath/ath11k/hal.c" "ath11k_hal_srng_src_sync_tp" "lazy source-ring hardware pointer reads"
require_text "$DPTX" "napi_consume_skb(msdu, budget);" "batched TX completion skb frees"
require_text "$MAC" "ath11k_mac_txq_work" "deferred TXQ bottom-half work"
require_text "$MAC" "work_pending(&ar->txq_work)" "coalesced TXQ wake work"
require_text "$PCIC" "irq_set_affinity_and_hint" "PCI IRQ affinity placement"
require_text "$PCIC" "irq_update_affinity_hint" "PCI IRQ affinity cleanup"
require_text "$AHB" "ath11k_ahb_ext_grp_disable(irq_grp);" "idempotent AHB IRQ disable"
# Keep AHB DP-ring interrupts distributed while leaving copy-engine groups on their default CPU.
require_text "$AHB" "static int ath11k_ahb_ext_irq_cpu(struct ath11k_base *ab, int i)" "AHB DP-ring CPU mapper"
require_text "$AHB" "ab->hw_params.ring_mask->rx[i]" "AHB REO ring affinity lookup"
require_text "$AHB" "ab->hw_params.ring_mask->tx[i]" "AHB TX completion ring affinity lookup"
require_text "$AHB" "cpumask_nth((ffs(rx) - 1) % num_online_cpus()," "AHB RX ring CPU distribution"
require_text "$AHB" "cpumask_nth((ffs(tx) - 1) % num_online_cpus()," "AHB TX ring CPU distribution"
require_text "$AHB" "irq_set_affinity_and_hint(ab->irq_num[irq_grp->irqs[j]]," "AHB DP IRQ affinity hint"
require_text "$AHB" "irq_update_affinity_hint(ab->irq_num[irq_grp->irqs[j]], NULL);" "AHB DP IRQ affinity cleanup"
# Verify the intended 512 MiB-router RX memory profile exactly.
require_define_value "$DPH" DP_RXDMA_BUF_RING_SIZE 2048 "RXDMA buffer ring"
require_define_value "$DPH" DP_RXDMA_REFILL_RING_SIZE 2048 "RXDMA refill ring"
require_define_value "$DPH" DP_RXDMA_ERR_DST_RING_SIZE 1024 "RXDMA error destination ring"
require_define_value "$DPH" DP_RXDMA_MON_STATUS_RING_SIZE 256 "RX monitor status ring"
require_define_value "$DPH" DP_RXDMA_MONITOR_BUF_RING_SIZE 256 "RX monitor buffer ring"
require_define_value "$DPH" DP_RXDMA_MONITOR_DST_RING_SIZE 512 "RX monitor destination ring"
require_define_value "$DPH" DP_RXDMA_MONITOR_DESC_RING_SIZE 256 "RX monitor descriptor ring"

# The experimental IDR-capacity patch that failed compilation must stay absent.
if grep -Fq "ath11k_dp_tx_idr_remove" "$DPTX"; then
  echo "::error::Ath11k preflight: obsolete experimental IDR helper is present"
  exit 1
fi

echo "::notice::Ath11k preflight passed: AQL, TXQ scheduling, page-pool RX, RX/TX buffer tables, refill protection, completion batching and IRQ affinity are present"
