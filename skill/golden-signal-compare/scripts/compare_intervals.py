#!/usr/bin/env python3
"""Greedy one-to-one event matching with TP/FP/FN and Se/PPV."""

from __future__ import annotations

import argparse
import pathlib
import sys


def load_values(path: pathlib.Path) -> list[int]:
    values = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        for token in line.replace(";", ",").split(","):
            token = token.strip()
            if token:
                values.append(int(token, 0))
    return sorted(values)


def match(reference: list[int], detected: list[int], tolerance: int):
    ref_used = [False] * len(reference)
    det_used = [False] * len(detected)
    pairs = []

    for di, d in enumerate(detected):
        candidates = [
            (abs(reference[ri] - d), ri)
            for ri, r in enumerate(reference)
            if not ref_used[ri] and abs(r - d) <= tolerance
        ]
        if candidates:
            _, ri = min(candidates)
            ref_used[ri] = True
            det_used[di] = True
            pairs.append((reference[ri], d, d - reference[ri]))

    tp = len(pairs)
    fp = sum(not used for used in det_used)
    fn = sum(not used for used in ref_used)
    se = 100.0 * tp / (tp + fn) if tp + fn else 0.0
    ppv = 100.0 * tp / (tp + fp) if tp + fp else 0.0
    return tp, fp, fn, se, ppv, pairs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", required=True)
    parser.add_argument("--detected", required=True)
    parser.add_argument("--tolerance", type=int, required=True)
    args = parser.parse_args()

    reference = load_values(pathlib.Path(args.reference))
    detected = load_values(pathlib.Path(args.detected))
    tp, fp, fn, se, ppv, pairs = match(reference, detected, args.tolerance)

    print("reference_count:", len(reference))
    print("detected_count :", len(detected))
    print("tolerance      :", args.tolerance)
    print("TP FP FN       :", tp, fp, fn)
    print(f"Se PPV (%)     : {se:.2f} {ppv:.2f}")
    for ref, det, delta in pairs:
        print(f"MATCH reference={ref} detected={det} delta={delta}")
    passed = fp == 0 and fn == 0
    print("RESULT:", "PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
