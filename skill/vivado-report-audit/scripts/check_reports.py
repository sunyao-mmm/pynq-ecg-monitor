#!/usr/bin/env python3
"""Parse common Vivado timing and utilization report fields."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def timing_stats(text: str):
    stats = {}
    for key in ("Setup", "Hold"):
        matches = re.findall(
            rf"{key}\s*:\s*(\d+)\s+Failing Endpoints,\s+Worst Slack\s+([-0-9.]+)ns",
            text,
        )
        if matches:
            failing = min(int(item[0]) for item in matches)
            worst = min(float(item[1]) for item in matches)
            stats[key.lower()] = {"failing_endpoints": failing, "worst_slack_ns": worst}
    periods = [float(x) for x in re.findall(r"period=([0-9.]+)ns", text)]
    if periods:
        stats["clock_period_ns"] = min(periods)
    return stats


def util_row(text: str, label: str):
    pattern = re.compile(
        rf"\|\s*{re.escape(label)}\s*\|\s*([0-9.]+)\s*\|.*?\|\s*([0-9.]+)\s*\|\s*$",
        re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        return None
    return {"used": float(match.group(1)), "util_pct": float(match.group(2))}


def utilization_stats(text: str):
    labels = {
        "lut": "Slice LUTs",
        "ff": "Slice Registers",
        "bram": "Block RAM Tile",
        "dsp": "DSPs",
    }
    return {key: util_row(text, label) for key, label in labels.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timing", required=True)
    parser.add_argument("--util", required=True)
    parser.add_argument("--min-wns", type=float, default=0.0)
    parser.add_argument("--min-whs", type=float, default=0.0)
    parser.add_argument("--max-lut-pct", type=float, default=None)
    parser.add_argument("--max-bram-pct", type=float, default=None)
    parser.add_argument("--max-dsp-pct", type=float, default=None)
    args = parser.parse_args()

    timing_text = read_text(Path(args.timing))
    util_text = read_text(Path(args.util))
    timing = timing_stats(timing_text)
    util = utilization_stats(util_text)

    checks = []

    def check(name: str, ok: bool, detail: str):
        checks.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")

    setup = timing.get("setup")
    hold = timing.get("hold")
    check(
        "setup_report_present",
        setup is not None,
        "missing Setup summary" if setup is None else repr(setup),
    )
    check(
        "hold_report_present",
        hold is not None,
        "missing Hold summary" if hold is None else repr(hold),
    )
    if setup:
        check(
            "wns",
            setup["failing_endpoints"] == 0 and setup["worst_slack_ns"] >= args.min_wns,
            f"failing={setup['failing_endpoints']} worst={setup['worst_slack_ns']} min={args.min_wns}",
        )
    if hold:
        check(
            "whs",
            hold["failing_endpoints"] == 0 and hold["worst_slack_ns"] >= args.min_whs,
            f"failing={hold['failing_endpoints']} worst={hold['worst_slack_ns']} min={args.min_whs}",
        )

    limits = {
        "lut": args.max_lut_pct,
        "bram": args.max_bram_pct,
        "dsp": args.max_dsp_pct,
    }
    for key, limit in limits.items():
        item = util.get(key)
        check(
            f"{key}_report_present",
            item is not None,
            "missing utilization row" if item is None else repr(item),
        )
        if item is not None and limit is not None:
            check(
                f"{key}_limit",
                item["util_pct"] <= limit,
                f"used={item['used']} pct={item['util_pct']} max={limit}",
            )

    print("SUMMARY:", {"timing": timing, "utilization": util})
    result = all(checks)
    print("RESULT:", "PASS" if result else "FAIL")
    return 0 if result else 1


if __name__ == "__main__":
    sys.exit(main())
