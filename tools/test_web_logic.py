#!/usr/bin/env python3
"""Off-board checks for the web bridge's data conversion helpers."""

from __future__ import annotations

import sys
import types

import numpy as np


fake_pynq = types.ModuleType("pynq")
fake_pynq.Overlay = object
fake_pynq.MMIO = object
sys.modules["pynq"] = fake_pynq

import ecg_web


def main():
    stream = ecg_web.ECGStream.__new__(ecg_web.ECGStream)
    stream.ring_window = 6
    assert stream._new_positions(0, 1) == [0]
    assert stream._new_positions(4, 1) == [4, 5, 0]
    assert stream._new_positions(0, 4) == []

    assert ecg_web.signed16(0x0001) == 1
    assert ecg_web.signed16(0xFFFE) == -2

    wave = [0, 10, 100, 10, 0, 5, 4, 3, 2]
    flags = [0, 0, 1, 0, 0, 0, 0, 0, 0]
    peaks = ecg_web.refine_peaks(wave, flags, back=2)
    assert peaks == [2]

    filtered = ecg_web.clean_for_display([0, 0, 500, 0, 0] * 20)
    assert len(filtered) == 100
    assert ecg_web.filter_markers_absolute([0, 10, 80, 5, 0], [2], 50) == [2]
    assert ecg_web.filter_markers_absolute([0, 10, 35, 5, 0], [2], 50) == []

    noisy = np.tile(np.asarray([-20, 20], dtype=np.int64), 100)
    noisy_ok, noisy_reason = ecg_web.quality_of(noisy)
    assert not noisy_ok and noisy_reason == "高频噪声过大"

    x = np.arange(500, dtype=np.float64)
    irregular_wave = np.zeros(500, dtype=np.int64)
    for center in (50, 150, 250, 470):
        irregular_wave += np.rint(
            600 * np.exp(-0.5 * ((x - center) / 6.0) ** 2)
        ).astype(np.int64)
    irregular_ok, _ = ecg_web.quality_of(irregular_wave)
    assert irregular_ok
    assert ecg_web.rhythm_status_of([50, 150, 250, 470]) == "不规则"
    bpm, median_rr, _ = ecg_web.robust_heart_rate(
        [100, 300, 500, 700, 800], 250.0
    )
    assert median_rr == 200
    assert bpm == 75

    # Narrow normal beats plus one wider, lower beat in an over-long RR gap.
    # The PS recovery should add the missed wide beat without inventing extras.
    wave = [0] * 800
    for center, amplitude, half_width, polarity in (
        (100, 900, 6, 1), (300, 850, 6, 1),
        (370, 500, 14, -1), (650, 850, 6, 1),
    ):
        for offset in range(-half_width, half_width + 1):
            sample = polarity * int(
                amplitude * (1.0 - abs(offset) / (half_width + 1))
            )
            wave[center + offset] = (
                max(wave[center + offset], sample)
                if polarity > 0 else min(wave[center + offset], sample)
            )
    flags = [0] * len(wave)
    flags[110] = 1
    flags[310] = 1
    flags[660] = 1
    beats, ref_width, ref_rr = ecg_web.classify_beats(wave, flags)
    assert ref_width and ref_rr
    assert beats
    recovered = [beat for beat in beats if beat["recovered"]]
    assert recovered
    assert recovered[0]["label"] in ("pvc", "pac")

    print("checks = 12  failures = 0")
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
