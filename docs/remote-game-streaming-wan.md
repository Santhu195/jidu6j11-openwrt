# Remote game-streaming WAN experiment

This branch is a separate experiment layered on top of the wireless-queueing branch. It keeps the existing JIDU6611 device support, ath11k AQL/TXQ scheduler, IRQ/RSS/RPS work, CAKE-MQ fairness/dither and QoSmate-compatible package set.

## Scope and safety

- The only kernel behavior change in this experiment is the CAKE-MQ diffserv4 tin-selection fix in patches/openwrt/0011-*.
- A read-only router diagnostic is installed as /usr/bin/jidu-wan-stream-diag. Run it with: sh /usr/bin/jidu-wan-stream-diag.
- No QoSmate UCI values are overwritten, no qdisc is changed at boot, no DSCP marking rule is installed, and no Tailscale/AdGuard service is modified.
- Keep the known-good wireless-queueing branch as the A/B baseline. This branch must not be considered better until both source preflight and full image build pass, followed by real WAN tests.

## Why the CAKE-MQ fix is included

The CAKE-MQ child qdiscs are created without their own qdisc handle. With IPv4 forwarding's default net.ipv4.ip_forward_update_priority=1, the network stack can rewrite skb->priority from the IP TOS byte. The old CAKE tin-override check then sees a zero child handle and can bypass DSCP selection. This affects diffserv4/diffserv8 on forwarded IPv4 traffic.

The upstream fix compares the priority major number with the parent CAKE-MQ handle for shared children, while leaving ordinary CAKE behavior unchanged. It was accepted into the Linux net-next tree on 2026-11-24. The patch is carried here as a targeted backport for the pinned OpenWrt 6.18 source.

For CAKE diffserv4, AF41 (DSCP 34) maps to the Video tin. Do not assume a Tailscale-encrypted stream arrives at the WAN with AF41, however: the router only sees the outer encrypted transport packet. Confirm the outer packet's DSCP first.

## Baseline before changing shaping

1. Run sh /usr/bin/jidu-wan-stream-diag while idle and save the output.
2. Repeat while a remote Moonlight stream is active.
3. Record the CAKE egress and IFB ingress rate, backlog, drops, overlimits and per-tin counters if exposed by the qdisc.
4. Measure sustained WAN upload and download at least three times, including a busy-hour run. Do not assume the configured 380000 kbit/s is below the real bottleneck in both directions.
5. Compare idle ping with loaded ping to multiple reflectors. The upload direction deserves special attention because the home PC sends the video stream outward.

Keep the current QoSmate settings as the control arm. For any later rate experiment, use a conservative shaper rate below the lowest repeatable real bottleneck rate (initially around 90–95% is a test range, not a universal setting). Change one direction at a time, and keep autorate min/base/max within the measured sustainable range. Do not lower the current minimum or raise the maximum until measurements justify it.

## Remote Samsung / Moonlight test

Run an iperf3 server on the home gaming PC, then from the Samsung client over the same remote route used by Moonlight (Tailscale when that is the intended path):

    iperf3 -s

From an iperf3 client on Android/Termux, test home-to-phone UDP throughput with modest steps:

    iperf3 -c <home-gaming-pc-tailscale-ip> -u -R -b 10M -t 60
    iperf3 -c <home-gaming-pc-tailscale-ip> -u -R -b 20M -t 60
    iperf3 -c <home-gaming-pc-tailscale-ip> -u -R -b 30M -t 60

Run a low-rate ping to the same host in parallel. Record UDP loss/jitter, ping median/p95/max, Moonlight network latency, decode time, frame pacing and dropped frames. Increase rates only while loss and jitter remain stable. Use the same client network, Tailscale route, stream resolution, frame rate and codec for A/B comparisons.

If the Tailscale path is DERP-relayed, record that separately; changing WAN shaping cannot remove relay distance. This experiment does not change Tailscale or attempt to force a direct path.

## Verify outer DSCP before prioritizing

While a stream is active, capture a small sample on the WAN:

    tcpdump -ni wan -c 60 -vv 'udp'

Check the outer UDP packets' DS field. AF41 is DSCP 34 (DS field 0x88 when ECN is zero). Only consider a targeted classification experiment after confirming whether the host's DSCP marking survives the encrypted tunnel. Do not classify every UDP packet as Video or Voice, and do not assume Sunshine's inner UDP ports (47998/47999/48000) are visible through Tailscale encryption.

The current QoSmate configuration washes DSCP on download but preserves it on upload; leave those settings unchanged for the first test. The CAKE-MQ parent-handle backport ensures forwarded IPv4 tin selection uses the proper parent handle rather than the zero child handle.

## A/B matrix

| Test | Control | WAN-shaping experiment |
|---|---|---|
| Idle | Current settings | Same |
| Remote stream only | Current settings | Same, compare CAKE counters |
| Stream + home upload load | Current settings | Measured upload cap |
| Stream + home download load | Current settings | Measured download cap |
| Stream + competing LAN client | Current settings | Same; check fairness |

Pass criteria: lower loaded p95/max latency and jitter without material UDP loss, no growing CAKE backlog/drops, no regressions in normal browsing or other clients, and no increase in Moonlight decode/frame-pacing time. Record throughput too; do not optimize only for ping.

## Explicit exclusions

- No new QoS manager and no replacement of QoSmate with SQM.
- No hardware flow offload enablement; it may bypass software qdisc shaping.
- No global DSCP rewrite, blanket UDP priority, or changes to WASHDSCP settings.
- No Tailscale changes, port-forwarding changes, firewall changes, or changes to live router configuration.
