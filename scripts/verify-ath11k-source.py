#!/usr/bin/env python3
"""Check that the ath11k TX-airtime patch landed inside its intended C function."""
from __future__ import annotations

import re
import sys
from pathlib import Path


def fail(message: str) -> int:
    print(f"::error::Ath11k source validation: {message}")
    return 1


def function_body(source: str) -> tuple[str, int, int] | None:
    pattern = re.compile(
        r"(?ms)^[ \t]*(?:static\s+)?void\s+ath11k_update_per_peer_tx_stats\s*\([^;]*?\)\s*\{"
    )
    match = pattern.search(source)
    if not match:
        return None

    opening = match.end() - 1
    depth = 0
    state = "code"
    escaped = False
    i = opening
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""

        if state == "line-comment":
            if ch == "\n":
                state = "code"
        elif state == "block-comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 1
        elif state in ("string", "char"):
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "code"
        else:
            if ch == "/" and nxt == "*":
                state = "block-comment"
                i += 1
            elif ch == "/" and nxt == "/":
                state = "line-comment"
                i += 1
            elif ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return source[match.start():i + 1], match.start(), i + 1
        i += 1
    return None


def main() -> int:
    if len(sys.argv) != 2:
        return fail("usage: verify-ath11k-source.py <path/to/dp_rx.c>")

    path = Path(sys.argv[1])
    if not path.is_file():
        return fail(f"missing source file: {path}")
    source = path.read_text(encoding="utf-8", errors="replace")
    found = function_body(source)
    if found is None:
        return fail("could not locate a complete ath11k_update_per_peer_tx_stats() definition")

    body, start, end = found
    outside = source[:start] + source[end:]
    required = {
        "one airtime_tid declaration": r"\bu8\s+airtime_tid\s*;",
        "one TID selection assignment": r"\bairtime_tid\s*=\s*tid\s*;",
        "one TX airtime registration": (
            r"ieee80211_sta_register_airtime\s*\(\s*sta\s*,\s*airtime_tid\s*,\s*tx_duration\s*,\s*0\s*\)\s*;"
        ),
    }
    for label, pattern in required.items():
        if len(re.findall(pattern, body)) != 1:
            return fail(f"expected exactly {label} inside ath11k_update_per_peer_tx_stats()")

    if re.search(r"\bairtime_tid\b", outside):
        return fail("airtime_tid code exists outside ath11k_update_per_peer_tx_stats(); a patch hunk may have landed at file scope")

    duration = body.find("arsta->tx_duration += tx_duration;")
    assignment = body.find("airtime_tid = tid;")
    registration = body.find("ieee80211_sta_register_airtime")
    if min(duration, assignment, registration) < 0 or not (duration < assignment < registration):
        return fail("TX airtime selection/registration is missing or out of order within the target function")

    if len(re.findall(r"\bairtime_tid\b", body)) != 6:
        return fail("airtime_tid references are duplicated or incomplete inside the target function")

    if not re.search(
        r"if\s*\(\s*tx_duration\s*\)\s*ieee80211_sta_register_airtime\s*\(",
        body,
    ):
        return fail("TX airtime registration is not guarded by if (tx_duration)")

    print("::notice::Ath11k TX-airtime code is scoped and ordered correctly inside ath11k_update_per_peer_tx_stats()")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
