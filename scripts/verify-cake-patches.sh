#!/usr/bin/env bash
set -euo pipefail

CAKE="${1:?usage: verify-cake-patches.sh <prepared-net-sched-sch_cake.c>}"
[ -s "$CAKE" ] || { echo "::error::CAKE preflight: missing prepared sch_cake.c: $CAKE"; exit 1; }

require_text() {
  local needle="$1" description="$2"
  if ! grep -Fq -- "$needle" "$CAKE"; then
    echo "::error::CAKE preflight: missing $description"
    exit 1
  fi
}

require_text 'timer_slack;' "CAKE timer slack field"
require_text 'qdisc_watchdog_schedule_range_ns(&q->watchdog, next,' "range-based shaper watchdog scheduling"
require_text 'qd->timer_slack = min_t(u64, 100 * NSEC_PER_USEC,' "four-packet/100-us timer slack cap"

range_count="$(grep -Fc 'qdisc_watchdog_schedule_range_ns(&q->watchdog, next,' "$CAKE" || true)"
if [ "$range_count" -ne 3 ]; then
  echo "::error::CAKE preflight: expected 3 range-watchdog sites, found $range_count"
  exit 1
fi

require_text 'static u16 cake_mq_count(' "CAKE-MQ sibling flow-count implementation"
require_text 'cake_mq_count_hosts(sch, now);' "cross-queue host/flow accounting"
require_text 'CAKE_MQ_BACKLOG_SHIFT' "backlog-aware CAKE-MQ rate sharing"
require_text 'rcu_dereference_bh(netdev_get_tx_queue(dev, ntx)->qdisc_sleeping)' "BH-safe sibling qdisc lookup"
require_text '#include <linux/prandom.h>' "per-tin PRNG header"
require_text 'struct rnd_state dither;' "per-tin PRNG state"
require_text '(u16)prandom_u32_state(&q->dither)' "per-tin quantum dithering"
require_text 'prandom_seed_state(&b->dither, get_random_u64());' "per-tin PRNG initialization"
require_text 'handle = q->is_shared ? TC_H_MAJ(sch->parent) : sch->handle;' "CAKE-MQ parent-handle selection for forwarded DSCP"
require_text 'TC_H_MAJ(skb->priority) == handle &&' "corrected CAKE-MQ tin-override handle check"

# Guard against accidentally integrating PPPoE-only transmit changes in this DHCP-WAN build.
if grep -Fq 'cake_pppoe_xmit' "$CAKE"; then
  echo "::error::CAKE preflight: unexpected PPPoE lockless transmit path in DHCP-WAN integration"
  exit 1
fi

echo "::notice::CAKE preflight passed: timer slack, CAKE-MQ fairness and per-tin dither are present"
