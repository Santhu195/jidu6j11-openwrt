#!/usr/bin/env python3
"""Fail fast on malformed unified-diff files in the custom ath11k patch series."""
from __future__ import annotations

import re
import sys
from pathlib import Path

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
BOUNDARIES = ("@@", "--- a/", "diff --git ", "-- ")


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "patches/ath11k")
    patches = sorted(root.glob("*.patch"))
    if not patches:
        print(f"::error::No ath11k patch files found in {root}")
        return 1

    errors: list[str] = []
    for path in patches:
        raw = path.read_bytes()
        if not raw.endswith(b"\n"):
            # Existing upstream-derived patch files may legitimately lack a
            # trailing newline. patch(1) can still apply them; keep this as a
            # formatting warning while enforcing every hunk's exact counts.
            print(f"::warning::{path}: missing final newline; unified-diff hunk counts will still be checked")
        try:
            lines = raw.decode("utf-8").splitlines()
        except UnicodeDecodeError as exc:
            errors.append(f"{path}: patch is not UTF-8: {exc}")
            continue

        # A doubled leading '+' in a unified-diff addition is usually an
        # accidentally retained patch marker, which would become literal C
        # source (for example, '+ return;') after patch(1) applies it.
        for lineno, line in enumerate(lines, 1):
            if re.fullmatch(r"\+\+[ \t]*(?:return;|})[ \t]*", line):
                errors.append(
                    f"{path}:{lineno}: added C line retains a literal diff '+' before return/brace"
                )

        i = 0
        while i < len(lines):
            match = HUNK_RE.match(lines[i])
            if not match:
                i += 1
                continue

            old_expected = int(match.group(2) or 1)
            new_expected = int(match.group(4) or 1)
            old_seen = new_seen = 0
            hunk_line = i + 1
            j = i + 1

            while j < len(lines):
                line = lines[j]
                if line.startswith(BOUNDARIES):
                    break

                if line == "":
                    # Some existing source patches encode an empty context line
                    # without its prefix. Count it only while a hunk still needs
                    # context; otherwise it can silently terminate the patch.
                    if old_seen < old_expected and new_seen < new_expected:
                        old_seen += 1
                        new_seen += 1
                        j += 1
                        continue

                    k = j + 1
                    while k < len(lines) and lines[k] == "":
                        k += 1
                    if k < len(lines) and lines[k].startswith("@@"):
                        errors.append(
                            f"{path}:{j + 1}: blank separator before a later hunk; "
                            "patch(1) stops before that hunk"
                        )
                    j += 1
                    break

                if line.startswith(" "):
                    old_seen += 1
                    new_seen += 1
                elif line.startswith("+"):
                    new_seen += 1
                elif line.startswith("-"):
                    old_seen += 1
                elif line.startswith("\\"):
                    pass
                else:
                    errors.append(
                        f"{path}:{j + 1}: invalid line in hunk started at line {hunk_line}: {line!r}"
                    )
                    j += 1
                    break

                if old_seen > old_expected or new_seen > new_expected:
                    errors.append(
                        f"{path}:{hunk_line}: hunk has too many lines "
                        f"(expected old/new {old_expected}/{new_expected}, "
                        f"found {old_seen}/{new_seen})"
                    )
                    break
                j += 1

            if old_seen != old_expected or new_seen != new_expected:
                errors.append(
                    f"{path}:{hunk_line}: hunk line-count mismatch "
                    f"(expected old/new {old_expected}/{new_expected}, "
                    f"found {old_seen}/{new_seen})"
                )
            i = max(i + 1, j)

    if errors:
        for error in errors:
            print(f"::error::{error}")
        return 1

    print(f"::notice::Validated unified-diff syntax and hunk counts for {len(patches)} ath11k patches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
