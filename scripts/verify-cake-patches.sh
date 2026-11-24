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

echo "::notice::CAKE preflight passed: current-tree shaper timer slack patch is present"
