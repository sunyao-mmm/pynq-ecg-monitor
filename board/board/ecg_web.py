#!/usr/bin/env python3
"""Continuous ECG web monitor for the PYNQ-Z2 overlay.

Uses CAP_LEN bit 31 as the continuous-ring switch.  The original capture mode
and pynq_ecg.py remain unchanged when that bit is clear.
"""

from __future__ import annotations

import argparse
import json
import socket
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
from pynq import MMIO, Overlay


CTRL = 0x00
STATUS = 0x04
CLT_PTR = 0x08
BPM = 0x14
RR = 0x18
BEAT_COUNT = 0x1C
RR_BAD = 0x20
CAP_LEN = 0x24
ID = 0x2C
CAP_ADDR = 0x30
CAP_DATA = 0x34

FS_NOMINAL = 250.0
FS_ADS1292 = 243.65
FIR_DELAY = 32
SEARCH = 22
CONT_FLAG = 1 << 31
PVC_GAP_S = 0.16
PVC_WIDE_MS = 120.0
PVC_WIDE_RATIO = 1.35
PVC_EARLY_RATIO = 0.80
PVC_MISS_AMP = 0.45
PVC_WIDTH_FRAC = 0.25
PVC_GAP_RATIO = 1.25
PVC_SHAPE_DIFF = 0.20
Q_AMP_FRAC = 0.15
Q_EXT_FRAC = 0.50
Q_HF_RATIO = 0.16
Q_RR_CV = 0.35


def _median_k(values, width=5):
    values = np.asarray(values, dtype=np.int64)
    if len(values) < width:
        return values.copy()
    half = width // 2
    padded = np.pad(values, (half, half), mode="edge")
    windows = np.stack([padded[i:i + len(values)] for i in range(width)], axis=1)
    return np.sort(windows, axis=1)[:, half]


def _moving_average(values, width):
    values = np.asarray(values, dtype=np.float64)
    width = max(1, int(width))
    if width <= 1 or len(values) < width:
        return values.copy()
    half = width // 2
    padded = np.pad(values, (half, width - 1 - half), mode="edge")
    return np.convolve(padded, np.ones(width) / width, mode="valid")[:len(values)]


def _despike_runs(values, max_width=4, scale=8.0):
    """Remove only short, isolated spikes; preserve real QRS complexes."""
    values = np.asarray(values, dtype=np.int64)
    if len(values) < 20:
        return values.copy()
    reference = _median_k(values, 9)
    deviation = values - reference
    noise = float(np.median(np.abs(deviation))) + 1e-6
    bad = np.abs(deviation) > max(25.0, scale * 1.4826 * noise)
    bad_positions = np.flatnonzero(bad)
    if not len(bad_positions):
        return values.copy()

    runs = []
    start = previous = int(bad_positions[0])
    for position in bad_positions[1:]:
        position = int(position)
        if position - previous > 1:
            runs.append((start, previous))
            start = position
        previous = position
    runs.append((start, previous))

    cleaned = values.astype(np.float64)
    for low, high in runs:
        if high - low + 1 > max_width:
            continue
        left = max(0, low - 1)
        right = min(len(values) - 1, high + 1)
        cleaned[low:high + 1] = np.linspace(
            cleaned[left], cleaned[right], high - low + 3
        )[1:-1]
    return cleaned.astype(np.int64)


def clean_for_display(values):
    values = _despike_runs(np.asarray(values, dtype=np.int64))
    baseline = _moving_average(values, int(FS_NOMINAL))
    return np.rint(values - baseline).astype(np.int64)


def refine_peaks(wave, flags, back=25):
    peaks = []
    for flag_index in np.flatnonzero(np.asarray(flags) == 1):
        low = max(0, int(flag_index) - back)
        segment = np.asarray(wave[low:int(flag_index) + 1], dtype=np.int64)
        if len(segment):
            peaks.append(low + int(np.argmax(segment)))
    return sorted(set(peaks))


def filter_markers(wave, peaks, frac=0.40):
    if not peaks:
        return []
    wave = np.asarray(wave, dtype=np.int64)
    amplitudes = []
    for peak in peaks:
        low = max(0, peak - 12)
        high = min(len(wave), peak + 13)
        segment = wave[low:high]
        amplitudes.append(int(segment.max() - segment.min()) if len(segment) else 0)
    reference = float(np.median(amplitudes)) if amplitudes else 0.0
    return [peak for peak, amp in zip(peaks, amplitudes) if amp >= frac * reference]


def filter_markers_absolute(wave, peaks, min_peak_to_peak):
    """Keep live R flags only when their local waveform amplitude is large enough."""
    wave = np.asarray(wave, dtype=np.int64)
    kept = []
    for peak in peaks:
        low = max(0, int(peak) - 12)
        high = min(len(wave), int(peak) + 13)
        segment = wave[low:high]
        if len(segment) and int(segment.max() - segment.min()) >= min_peak_to_peak:
            kept.append(int(peak))
    return kept


def beat_features(wave, peak):
    """Measure a baseline-corrected QRS and its normalized morphology."""
    raw = np.asarray(wave, dtype=np.float64)
    peak = int(peak)
    edge_low = max(0, peak - 35)
    edge_high = min(len(raw), peak + 36)
    local = raw[edge_low:edge_high]
    edge_width = min(8, max(1, len(local) // 4))
    baseline = float(np.median(np.concatenate((local[:edge_width], local[-edge_width:]))))

    search_low = max(0, peak - 12)
    search_high = min(len(raw), peak + 13)
    center = search_low + int(np.argmax(np.abs(raw[search_low:search_high] - baseline)))
    absolute_delta = np.abs(raw - baseline)
    amplitude = int(absolute_delta[center])
    threshold = max(3.0, PVC_WIDTH_FRAC * amplitude)
    low = high = center
    while low > 0 and absolute_delta[low - 1] > threshold:
        low -= 1
    while high < len(absolute_delta) - 1 and absolute_delta[high + 1] > threshold:
        high += 1

    shape_half = 18
    shape = np.zeros(shape_half * 2 + 1, dtype=np.float64)
    shape_low = center - shape_half
    shape_high = center + shape_half + 1
    valid_low = max(0, shape_low)
    valid_high = min(len(raw), shape_high)
    if valid_high > valid_low:
        segment = raw[valid_low:valid_high] - baseline
        scale = float(np.max(np.abs(segment))) if len(segment) else 0.0
        if scale > 0:
            shape[valid_low - shape_low:valid_high - shape_low] = segment / scale

    return {
        "peak": center,
        "amp": amplitude,
        "width": high - low + 1,
        "lo": low,
        "hi": high,
        "shape": shape,
    }


def find_beat_candidates(wave, flags):
    """Combine PL R flags with PS recovery of convincing missed QRS complexes."""
    wave = np.asarray(wave, dtype=np.int64)
    if not len(wave):
        return [], set()

    hardware = refine_peaks(wave, flags)
    if hardware:
        hardware_amp = np.abs(wave[hardware])
        reference_amp = float(np.median(hardware_amp))
        if reference_amp > 0:
            hardware = [
                peak for peak in hardware
                if abs(int(wave[peak])) >= 0.20 * reference_amp
            ]
    hardware_set = set(hardware)
    peaks = list(hardware)
    if len(peaks) < 2:
        return sorted(peaks), hardware_set

    absolute = np.abs(wave)
    gap = max(3, int(PVC_GAP_S * FS_NOMINAL))
    threshold = max(25.0, PVC_MISS_AMP * np.median(absolute[peaks]))

    # Only inspect RR gaps that are clearly longer than the recent beat
    # cadence.  Scanning every interval creates false beats on T waves and
    # broad baseline motion, especially in the short looping demo ROM.
    rr_values = np.diff(peaks)
    reference_rr = float(np.median(rr_values)) if len(rr_values) else 0.0
    if reference_rr > 0:
        for left, right in zip(peaks[:-1], peaks[1:]):
            if right - left < PVC_GAP_RATIO * reference_rr:
                continue
            low = int(left) + gap
            high = int(right) - gap
            if high <= low:
                continue
            candidate = low + int(np.argmax(absolute[low:high]))
            if absolute[candidate] < threshold:
                continue
            feature = beat_features(wave, candidate)
            # Reject one-point spikes and very broad baseline motion.
            if 3 <= feature["width"] <= int(0.22 * FS_NOMINAL):
                peaks.append(candidate)

    return sorted(set(peaks)), hardware_set


def classify_beats(wave, flags):
    """Return normal/PVC/PAC candidates from the analysis window."""
    peaks, hardware = find_beat_candidates(wave, flags)
    features = [beat_features(wave, peak) for peak in peaks]
    if not features:
        return [], None, None

    widths = np.asarray([feature["width"] for feature in features], dtype=float)
    rr_values = np.asarray(
        [features[i]["peak"] - features[i - 1]["peak"] for i in range(1, len(features))],
        dtype=float,
    )
    half = max(2, int(np.ceil(len(widths) / 2.0)))
    reference_width = float(np.median(np.sort(widths)[:half]))
    reference_rr = float(np.median(rr_values)) if len(rr_values) else 0.0
    rr_cv = (
        float(np.std(rr_values) / np.mean(rr_values))
        if len(rr_values) and np.mean(rr_values) > 0 else 1.0
    )
    narrow_limit = max(reference_width * 1.25, reference_width + 2.0)
    absolute_narrow_limit = int(round(PVC_WIDE_MS * FS_NOMINAL / 1000.0))
    normal_features = [
        feature for feature in features
        if feature["width"] <= narrow_limit
        and feature["width"] <= absolute_narrow_limit
    ]
    has_normal_reference = bool(normal_features)
    if not normal_features:
        normal_features = features[:]
    template = np.median(
        np.asarray([feature["shape"] for feature in normal_features]), axis=0
    )

    beats = []
    for index, feature in enumerate(features):
        rr_value = (
            feature["peak"] - features[index - 1]["peak"] if index > 0 else None
        )
        wide = (
            feature["width"] > PVC_WIDE_RATIO * reference_width
            or feature["width"] / FS_NOMINAL * 1000.0 > PVC_WIDE_MS
        )
        early = (
            rr_value is not None
            and reference_rr > 0
            and rr_value < PVC_EARLY_RATIO * reference_rr
        )
        template_energy = float(np.linalg.norm(template))
        beat_energy = float(np.linalg.norm(feature["shape"]))
        correlation = (
            float(np.dot(feature["shape"], template) / (beat_energy * template_energy))
            if beat_energy > 0 and template_energy > 0 else 1.0
        )
        shape_difference = 1.0 - float(np.clip(correlation, -1.0, 1.0))
        morphology_abnormal = shape_difference >= PVC_SHAPE_DIFF
        recovered = all(
            abs(feature["peak"] - hardware_peak) > 6 for hardware_peak in hardware
        )

        all_beats_wide = len(features) >= 2 and all(w > absolute_narrow_limit for w in widths)
        wide_rhythm_stable = all_beats_wide and rr_cv <= 0.25
        if wide and (
            (has_normal_reference and early and morphology_abnormal)
            or (not has_normal_reference and wide_rhythm_stable)
        ):
            label = "pvc"
        elif wide:
            label = "uncertain"
        elif early and shape_difference < 0.20 and rr_value < 0.70 * reference_rr:
            label = "pac"
        elif early:
            label = "uncertain"
        else:
            label = "normal"
        beats.append({
            **feature,
            "label": label,
            "rr": rr_value,
            "recovered": recovered,
            "shape_difference": shape_difference,
            "rr_cv": rr_cv,
        })

    return beats, reference_width, reference_rr


def rhythm_status_of(peaks):
    if not peaks or len(peaks) < 4:
        return "样本不足"
    intervals = np.diff(np.asarray(sorted(peaks), dtype=np.int64))
    mean_rr = float(np.mean(intervals))
    if mean_rr <= 0:
        return "样本不足"
    rr_cv = float(np.std(intervals) / mean_rr)
    if rr_cv <= Q_RR_CV:
        return "规则"
    return "不规则"


def robust_heart_rate(peaks, sample_rate):
    """Calculate BPM from physiological RR intervals using a short median."""
    if not peaks or len(peaks) < 2:
        return 0, 0, 0.0
    intervals = np.diff(np.asarray(sorted(peaks), dtype=np.int64))
    rr_min = int(round(60.0 * sample_rate / 200.0))
    rr_max = int(round(60.0 * sample_rate / 30.0))
    intervals = intervals[(intervals >= rr_min) & (intervals <= rr_max)]
    if not len(intervals):
        return 0, 0, 0.0
    recent = intervals[-4:]
    median_rr = int(round(float(np.median(recent))))
    bpm = int(round(60.0 * sample_rate / median_rr)) if median_rr else 0
    rr_cv = float(np.std(recent) / np.mean(recent)) if np.mean(recent) > 0 else 0.0
    return bpm, median_rr, rr_cv


def quality_of(wave):
    if len(wave) < 30:
        return False, "等待数据"
    values = np.asarray(wave, dtype=np.int64)
    ac = values - float(np.median(values))
    span = int(ac.max() - ac.min())
    if span < 30:
        return False, "几乎没有信号"
    amplitude = int(np.abs(ac).max())
    if amplitude > Q_AMP_FRAC * 32768:
        return False, "输入可能过载"
    if len(ac) >= 20:
        scale = float(np.percentile(np.abs(ac), 95)) + 1e-6
        roughness = float(np.median(np.abs(np.diff(ac)))) / scale
        if roughness > Q_HF_RATIO:
            return False, "高频噪声过大"
    half = max(1.0, span / 2.0)
    extreme_fraction = float(np.mean(np.abs(ac) > 0.6 * half))
    if extreme_fraction > Q_EXT_FRAC:
        return False, "基线异常，像方波或导联脱落"
    return True, "信号通过"


def signed16(word):
    value = int(word) & 0xFFFF
    return value - 0x10000 if value >= 0x8000 else value


class ECGStream:
    def __init__(
        self, bitfile, source=0, window=1000, analysis_window=2000,
        warmup=420, poll_s=0.05, live_min_peak_to_peak=80,
    ):
        self.overlay = Overlay(str(bitfile))
        self.mm = MMIO(self.overlay.ip_dict["ecg_axil_0"]["phys_addr"], 0x1000)
        self.source = int(source)
        self.display_window = max(200, min(int(window), 2047))
        self.analysis_window = max(
            self.display_window, min(int(analysis_window), 2047)
        )
        self.ring_window = self.analysis_window
        self.warmup = max(0, int(warmup))
        self.poll_s = max(0.02, float(poll_s))
        self.live_min_peak_to_peak = max(1, int(live_min_peak_to_peak))
        self.lock = threading.RLock()
        self.board_lock = threading.RLock()
        self.wave = deque(maxlen=self.analysis_window)
        self.clt = deque(maxlen=self.analysis_window)
        self.flags = deque(maxlen=self.analysis_window)
        self.read_cursor = None
        self.warmup_left = self.warmup
        self.running = False
        self.worker = None
        self.metrics = {
            "bpm": 0,
            "rr": 0,
            "beat_count": 0,
            "rr_bad": 0,
            "signal_valid": False,
            "quality": False,
            "quality_text": "等待数据",
            "rhythm_status": "样本不足",
            "normal_peaks": [],
            "pvc_peaks": [],
            "r_peaks": [],
            "pvc_count": 0,
            "recovered_count": 0,
            "pl_peaks_window": 0,
            "frame": [],
        }
        self._configure(self.source)

    def read(self, offset):
        return int(self.mm.read(int(offset)))

    def write(self, offset, value):
        self.mm.write(int(offset), int(value))

    def _configure(self, source):
        with self.board_lock:
            src_bit = 0x04 if source else 0x00
            cap_word = CONT_FLAG | self.ring_window
            self.write(CAP_LEN, cap_word)
            self.write(CTRL, 0x02 | src_bit)
            time.sleep(0.05)
            self.write(CTRL, 0x01 | src_bit)
        with self.lock:
            self.source = int(source)
            self.wave.clear()
            self.clt.clear()
            self.flags.clear()
            self.read_cursor = None
            self.warmup_left = self.warmup
            self.running = True
            self.metrics.update(
                bpm=0, rr=0, beat_count=0, rr_bad=0, signal_valid=False,
                quality=False, quality_text="等待数据",
                rhythm_status="样本不足",
                normal_peaks=[], pvc_peaks=[], r_peaks=[],
                pvc_count=0, recovered_count=0,
                pl_peaks_window=0, frame=[],
            )

    def _read_pointer(self):
        with self.board_lock:
            return (self.read(CLT_PTR) >> 16) & 0xFFFF

    def _read_sample(self, ring_position):
        word_address = 2 * int(ring_position) + 1
        with self.board_lock:
            self.write(CAP_ADDR, word_address)
            wave_word = self.read(CAP_DATA)
            self.write(CAP_ADDR, word_address + 1)
            clt_word = self.read(CAP_DATA)
        return signed16(wave_word), (int(wave_word) >> 16) & 1, int(clt_word) & 0x00FFFFFF

    def _new_positions(self, previous, current):
        delta = (current - previous) % self.ring_window
        if delta > self.ring_window // 2:
            return []
        return [(previous + i) % self.ring_window for i in range(delta)]

    def _refresh_display(self):
        with self.lock:
            wave_analysis = list(self.wave)
            clt_analysis = list(self.clt)
            flags = list(self.flags)
        offset = max(0, len(wave_analysis) - self.display_window)
        wave = wave_analysis[offset:]
        clt = clt_analysis[offset:]
        displayed = (
            clean_for_display(wave)
            if len(wave) >= 20
            else np.asarray(wave, dtype=np.int64)
        )
        hardware_all = refine_peaks(wave_analysis, flags)
        hardware_filtered = filter_markers_absolute(
            wave_analysis, hardware_all, self.live_min_peak_to_peak
        )
        ok, quality_text = quality_of(wave)
        beats = []
        if ok and len(wave_analysis) >= 40:
            beats, _reference_width, _reference_rr = classify_beats(
                wave_analysis, flags
            )
        classified_peaks = [int(beat["peak"]) for beat in beats]
        rhythm_status = rhythm_status_of(classified_peaks)

        normal_peaks = []
        pvc_peaks = []
        recovered_count = 0
        for beat in beats:
            peak = int(beat["peak"])
            if peak < offset or peak >= len(wave_analysis):
                continue
            display_peak = peak - offset
            if beat["recovered"]:
                recovered_count += 1
            if beat["label"] == "pvc":
                pvc_peaks.append(display_peak)
            elif beat["label"] == "normal":
                normal_peaks.append(display_peak)

        sample_rate = FS_ADS1292 if self.source == 1 else FS_NOMINAL
        rate_peaks = classified_peaks if self.source == 1 else hardware_filtered
        ps_bpm, ps_rr, _ps_rr_cv = robust_heart_rate(rate_peaks, sample_rate)
        raw_bpm = self.read(BPM) & 0xFFFF
        bpm = ps_bpm if self.source == 1 else raw_bpm
        rr_value = ps_rr if self.source == 1 else self.read(RR)
        with self.lock:
            self.metrics = {
                "bpm": bpm,
                "rr": rr_value,
                "beat_count": self.read(BEAT_COUNT),
                "rr_bad": self.read(RR_BAD),
                "signal_valid": ok,
                "quality": ok,
                "quality_text": quality_text,
                "rhythm_status": rhythm_status,
                "normal_peaks": normal_peaks,
                "pvc_peaks": pvc_peaks,
                "r_peaks": [],
                "pvc_count": len(pvc_peaks),
                "recovered_count": recovered_count,
                "pl_peaks_window": int(np.sum(flags[offset:])),
                "frame": displayed.astype(int).tolist(),
                "clt": clt,
            }

    def _worker(self):
        last_status = 0.0
        while True:
            if not self.running:
                time.sleep(0.10)
                continue
            pointer = self._read_pointer()
            if self.read_cursor is None:
                self.read_cursor = pointer
                time.sleep(0.20)
                continue
            positions = self._new_positions(self.read_cursor, pointer)
            for position in positions:
                wave, flag, clt = self._read_sample(position)
                if self.warmup_left:
                    self.warmup_left -= 1
                else:
                    with self.lock:
                        self.wave.append(wave)
                        self.flags.append(flag)
                        self.clt.append(clt)
            self.read_cursor = pointer
            now = time.monotonic()
            if now - last_status > 0.10:
                self._refresh_display()
                last_status = now
            time.sleep(self.poll_s)

    def start(self):
        with self.lock:
            if self.running:
                return
        self._configure(self.source)

    def stop(self):
        with self.lock:
            self.running = False
        with self.board_lock:
            self.write(CTRL, 0x04 if self.source else 0x00)

    def switch(self, source):
        self.stop()
        self._configure(int(source))

    def state(self):
        with self.lock:
            return {
                "running": self.running,
                "source": self.source,
                "source_name": "实时 ADS1292 监测" if self.source else "MIT-BIH ROM 离线分析",
                "window": self.display_window,
                "analysis_window": self.analysis_window,
                "samples": min(len(self.wave), self.display_window),
                "analysis_samples": len(self.wave),
                **self.metrics,
            }

    def serve(self):
        thread = threading.Thread(target=self._worker, daemon=True)
        thread.start()
        self.worker = thread


def make_handler(stream, page_path):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            return

        def _send_bytes(self, body, content_type):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, payload):
            self._send_bytes(json.dumps(payload).encode("utf-8"), "application/json")

        def do_GET(self):
            if self.path.startswith("/api/state"):
                self._json(stream.state())
                return
            if self.path in ("/", "/index.html"):
                self._send_bytes(page_path.read_bytes(), "text/html; charset=utf-8")
                return
            self.send_error(404)

        def do_POST(self):
            if self.path == "/api/start":
                stream.start()
            elif self.path == "/api/stop":
                stream.stop()
            elif self.path == "/api/source/0":
                stream.switch(0)
            elif self.path == "/api/source/1":
                stream.switch(1)
            else:
                self.send_error(404)
                return
            self._json({"ok": True, **stream.state()})

    return Handler


def board_url(port):
    try:
        address = socket.gethostbyname(socket.gethostname())
        if address.startswith("127."):
            address = socket.gethostbyname(socket.gethostname() + ".local")
    except Exception:
        address = "<board-ip>"
    return f"http://{address}:{port}/"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bit", default="ecg_bd_wrapper.bit")
    parser.add_argument("--window", type=int, default=1000)
    parser.add_argument("--analysis-window", type=int, default=2000)
    parser.add_argument("--live-min-p2p", type=int, default=80)
    parser.add_argument("--source", type=int, choices=(0, 1), default=0)
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    page_path = Path(__file__).with_name("index.html")
    stream = ECGStream(
        args.bit,
        source=args.source,
        window=args.window,
        analysis_window=args.analysis_window,
        live_min_peak_to_peak=args.live_min_p2p,
    )
    if (stream.read(ID) != 0x0EC60001):
        raise SystemExit("Overlay ID mismatch; check bit/hwh and ecg_axil_0")
    stream.serve()

    server = ThreadingHTTPServer((args.host, args.port), make_handler(stream, page_path))
    print("ECG web monitor:", board_url(args.port), flush=True)
    print("Ctrl+C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        stream.stop()
        server.shutdown()


if __name__ == "__main__":
    main()
