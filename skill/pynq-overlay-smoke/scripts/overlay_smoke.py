#!/usr/bin/env python3
"""Minimal on-board PYNQ Overlay and AXI-Lite smoke test."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


def parse_int(value):
    if isinstance(value, int):
        return value
    return int(str(value), 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", required=True)
    parser.add_argument("--hwh", required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    bit_path = pathlib.Path(args.bit)
    hwh_path = pathlib.Path(args.hwh)
    config_path = pathlib.Path(args.config)

    if not bit_path.exists() or not hwh_path.exists():
        print("RESULT: FAIL - .bit or .hwh does not exist")
        return 2
    if bit_path.stem != hwh_path.stem:
        print("RESULT: FAIL - .bit and .hwh must have the same base name")
        return 2
    if not config_path.exists():
        print("RESULT: FAIL - register config does not exist")
        return 2

    try:
        from pynq import MMIO, Overlay
    except Exception as exc:
        print("RESULT: FAIL - cannot import pynq:", exc)
        return 2

    cfg = json.loads(config_path.read_text(encoding="utf-8"))
    ip_name = cfg["ip_name"]

    try:
        overlay = Overlay(str(bit_path))
    except Exception as exc:
        print("RESULT: FAIL - Overlay load failed:", exc)
        return 1

    if ip_name not in overlay.ip_dict:
        print("RESULT: FAIL - IP not found:", ip_name)
        print("available:", ", ".join(sorted(overlay.ip_dict)))
        return 1

    base = overlay.ip_dict[ip_name]["phys_addr"]
    mmio = MMIO(base, 0x1000)
    checks = []
    print("IP:", ip_name)
    print("BASE:", hex(base))

    id_check = cfg.get("id")
    if id_check:
        offset = parse_int(id_check["offset"])
        expected = parse_int(id_check["expected"])
        actual = mmio.read(offset)
        ok = actual == expected
        checks.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} ID offset={hex(offset)} expected={hex(expected)} actual={hex(actual)}")

    for item in cfg.get("roundtrip", []):
        name = item.get("name", "register")
        offset = parse_int(item["offset"])
        value = parse_int(item["value"])
        mask = parse_int(item.get("mask", "0xFFFFFFFF"))
        mmio.write(offset, value)
        actual = mmio.read(offset) & mask
        expected = value & mask
        ok = actual == expected
        checks.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} offset={hex(offset)} expected={hex(expected)} actual={hex(actual)}")

    run_check = cfg.get("run_check")
    if run_check:
        ctrl_offset = parse_int(run_check["ctrl_offset"])
        status_offset = parse_int(run_check["status_offset"])
        run_bit = parse_int(run_check.get("run_bit", 0))
        settle_s = float(run_check.get("settle_s", 0.05))
        import time

        mmio.write(ctrl_offset, 1 << run_bit)
        time.sleep(settle_s)
        run_status = mmio.read(status_offset) & (1 << run_bit)
        mmio.write(ctrl_offset, 0)
        time.sleep(settle_s)
        stop_status = mmio.read(status_offset) & (1 << run_bit)
        ok = bool(run_status) and not bool(stop_status)
        checks.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} CTRL/STATUS run bit toggled")

    if not checks:
        print("RESULT: FAIL - no checks configured")
        return 2

    passed = all(checks)
    print(f"checks={len(checks)} failures={sum(not x for x in checks)}")
    print("RESULT:", "PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
