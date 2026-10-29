#!/usr/bin/env python3
"""Build an ecg_rom .coe (250 Hz, 1024 words) from a record of the MIT-BIH
arrhythmia database, using exactly the same convention as the existing
ecg_rom.coe (record 100):

    raw ADC (MIT-BIH "format 212")  ->  (raw-1024)*5   (same scaling the
                                        vendor script got via p_signal*1000)
    1024 samples at 360 Hz          ->  sinc resample to 250 Hz  -> 711 samples
    711 samples                     ->  padded to the 1024-deep BMG

Usage:
    python make_coe.py --db <dir> --record 119 --out ecg_rom_119.coe
    python make_coe.py --db <dir> --record 100 --check ../ecg_rom.coe
"""
import argparse
import pathlib
import re

import numpy as np

FS_IN, FS_OUT = 360.0, 250.0
WIN = 1024                     # source samples held in the ROM
ROM_LEN = 711                  # WIN * 250/360, rounded
BMG_DEPTH = 1024               # BMG is 1024 deep; only the first ROM_LEN play

# MIT-BIH annotation codes (only the ones we care about)
ANN_NAME = {1: "N", 2: "L", 3: "R", 4: "a", 5: "V", 6: "F", 7: "J", 8: "A",
            9: "S", 10: "E", 11: "j", 12: "/", 13: "Q", 16: "|", 17: "+",
            22: '"', 23: "~", 25: "s", 26: "T", 27: "*", 28: "D", 29: "=",
            31: "@", 32: "(", 33: ")", 34: "p", 35: "t", 36: "u", 37: "`",
            38: "'", 40: "[", 41: "]", 42: "e", 43: "n", 44: "o", 45: "r",
            46: "S", 47: "V", 48: "V", 49: "V", 50: "V"}


# ---------------------------------------------------------------- files
def read_dat(path):
    """MIT-BIH format 212 -> two int16 channels."""
    b = np.frombuffer(pathlib.Path(path).read_bytes(), dtype=np.uint8)
    b = b[: (len(b) // 3) * 3].reshape(-1, 3).astype(np.int32)
    # format 212: sample0 = byte0 + low nibble of byte1, sample1 = byte2 + high
    # nibble of byte1  (verified against the "initial value" fields of the .hea)
    s0 = (b[:, 0] | ((b[:, 1] & 0x0F) << 8)) - 1024
    s1 = (b[:, 2] | ((b[:, 1] >> 4) << 8)) - 1024
    # one frame (3 bytes) carries one sample of each channel, so s0/s1 are
    # already the two per-channel streams
    return s0, s1


def read_atr(path):
    """Parse a WFDB annotation file -> list of (sample_index, type)."""
    d = pathlib.Path(path).read_bytes()
    i, t, skip, out = 0, 0, 0, []
    while i + 1 < len(d):
        b0, b1 = d[i], d[i + 1]
        i += 2
        # WFDB annotation pair: byte0 = low 8 bits of the interval,
        # byte1 = (type << 2) | (interval >> 8).  (Verified by decoding
        # record 119: this yields clean N/V sequences and a total time equal
        # to the record length.)
        atype = b1 >> 2
        interval = ((b1 & 0x03) << 8) | b0
        if atype == 59:                      # SKIP
            skip = interval
            continue
        if atype in (60, 61, 62):            # NUM / SUB / CHN
            continue
        if atype == 63:                      # AUX (length = interval)
            i += interval
            continue
        # Empirically verified against the signal of records 100/119: the
        # "SKIP" multiplier does NOT apply in these files - adding the raw
        # intervals keeps every annotation aligned with its QRS (|offset|<=60
        # samples) and the total time matches the record length.
        t += interval
        skip = 0
        # NOTE: type 0 (NOTQRS) is a legal *marker* in the middle of the file,
        # so do NOT stop on it - only the final 0x00 0x00 pair ends the file.
        out.append((t, atype))
        if atype == 0 and interval == 0 and i >= len(d) - 2:
            break
    return out


# ---------------------------------------------------------------- dsp
def resample_sinc(x, fs_in, fs_out, taps=33):
    """Same band-limited resampler as tools/migrate_250hz.py."""
    ratio = fs_out / fs_in
    n = int(np.floor(len(x) * ratio))
    t = np.arange(n) / ratio
    half = taps // 2
    d = np.arange(-half, half + 1)
    w = np.sinc(d) * (0.5 + 0.5 * np.cos(np.pi * d / half))
    y = np.zeros(n)
    for k in range(n):
        i0 = int(np.floor(t[k])) - half
        idx = i0 + np.arange(taps)
        m = (idx >= 0) & (idx < len(x))
        ww = w * m
        s = ww.sum()
        y[k] = np.sum(x[np.clip(idx, 0, len(x) - 1)] * ww) / s if s else 0.0
    return y


def read_coe_hex(path):
    body = pathlib.Path(path).read_text().split("memory_initialization_vector")[1]
    v = [int(m, 16) for m in re.findall(r"[0-9a-fA-F]{1,4}", body)]
    return np.array([a - 65536 if a >= 32768 else a for a in v], dtype=int)


def write_coe(path, values):
    lines = ["memory_initialization_radix=16;", "memory_initialization_vector="]
    for i, v in enumerate(values):
        lines.append("%04x%s" % (int(v) & 0xFFFF, ";" if i == len(values) - 1 else ","))
    pathlib.Path(path).write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------- main
def build(db, record, win_start, scale=5):
    ch0, _ = read_dat(pathlib.Path(db) / ("%s.dat" % record))
    x = ch0[win_start:win_start + WIN].astype(np.int64) * scale
    y = np.round(resample_sinc(x, FS_IN, FS_OUT)).astype(np.int64)
    assert len(y) == ROM_LEN, "resampled %d != %d" % (len(y), ROM_LEN)
    pad = np.concatenate([y, y[: BMG_DEPTH - ROM_LEN]])
    return x, y, pad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--record", default="119")
    ap.add_argument("--start", type=int, default=None, help="window start (360 Hz samples)")
    ap.add_argument("--out", default=None)
    ap.add_argument("--check", default=None, help="compare record 100 with this existing coe")
    ap.add_argument("--list-pvc", action="store_true", help="list PVC positions and exit")
    a = ap.parse_args()

    db = pathlib.Path(a.db)

    if a.check:
        x, y, _ = build(db, "100", 0)
        ref = read_coe_hex(a.check)[:ROM_LEN]
        diff = np.abs(y - ref)
        print("check record 100 vs %s" % a.check)
        print("  max |diff| = %d, mean |diff| = %.2f, identical = %s"
              % (diff.max(), diff.mean(), bool(diff.max() == 0)))
        print("  mine  [:8] =", y[:8].tolist())
        print("  file  [:8] =", ref[:8].tolist())
        return

    ann = read_atr(db / ("%s.atr" % a.record))
    beats = [(t, ANN_NAME.get(ty, "?%d" % ty)) for t, ty in ann if ty in ANN_NAME]

    if a.list_pvc:
        print("record %s: %d annotations" % (a.record, len(beats)))
        for t, n in beats[:80]:
            print("  %8d  %s" % (t, n))
        return

    start = a.start if a.start is not None else 0
    inside = [(t - start, n) for t, n in beats if start <= t < start + WIN]
    print("window [%d, %d) at 360 Hz = %.2f s; beats inside:" % (start, start + WIN, WIN / FS_IN))
    for off, n in inside:
        print("   +%4d (250Hz:%4d)  %s" % (off, round(off * FS_OUT / FS_IN), n))

    x, y, pad = build(db, a.record, start)
    print("source window: min %d max %d ; resampled(250Hz): min %d max %d"
          % (x.min(), x.max(), y.min(), y.max()))

    if a.out:
        write_coe(a.out, pad)
        print("wrote %s (%d words)" % (a.out, len(pad)))


if __name__ == "__main__":
    main()
