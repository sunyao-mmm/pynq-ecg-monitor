#!/usr/bin/env python3
"""validate_mitdb.py -- 用整条 MIT-BIH 记录评估 PL 里的 R 峰检测器。

做两件事：
  1) 把 FPGA 里的定点算法在 Python 里**逐位复刻**
       notch_50hz.v (Q15 biquad, 带饱和)
       fir_bandpass.v (65 抽头 Q15, 折叠对称, sat16)
       clt_qrs.v (滑窗曲线长度 + 自适应阈值状态机)
     并用 record 100 的已知结果（R 峰 54/258/461/658）自校验。
  2) 对一批记录跑完整 30 分钟，和数据库标注比对（±150 ms 容差），
     输出 每条记录的 TP/FN/FP、Se/PPV 汇总表。

用法：
    python validate_mitdb.py --db <MIT-BIH目录> --out report.md [--records 100,101,...]
"""
import argparse
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "rom"))
import make_coe as MC          # 复用它的 read_dat / read_atr / resample_sinc

FS_IN, FS_OUT = 360.0, 250.0
TOL = 0.150                    # 比对容差 150 ms（WFDB 标准做法）

# ---- clt_qrs.v / ecg_detect_top.v 的参数（必须和 RTL 一致）----
LEARN, SEARCH, REFRACT, REL_PERIOD = 30, 22, 100, 250
LOW_THR_NUM, RR_MIN, RR_MAX = 12, 108, 720
CLT_W, C_CONST = 21, 2
THR_NUM, TH_OFF = 13, 5
FIR_DELAY = 32
TAPS = 65


# ---------------------------------------------------------------- 定点算法
def notch_q15(x):
    """notch_50hz.v：y = sat16((C0x+C1x1+C2x2+D1y1+D2y2+16384)>>15)"""
    c0, c1, c2, d1, d2 = 30912, -17172, 30912, 17172, -29055
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0
    for k in range(len(x)):
        acc = c0 * x[k] + c1 * x1 + c2 * x2 + d1 * y1 + d2 * y2 + 16384
        v = acc >> 15                                  # 算术右移
        if v > 32767:
            v = 32767
        elif v < -32768:
            v = -32768
        x2, x1 = x1, x[k]
        y2, y1 = y1, v
        y[k] = v
    return y


# fir_bandpass.v 里的 33 个折叠系数（Q15）—— 直接内嵌，这样本脚本不依赖
# 工程里的 .v 文件，放到任何地方都能单独跑。
FIR_COEF_Q15 = (38, 12, -11, -10, 21, 60, 61, 0, -90, -130, -67, 46, 69, -97,
                -380, -555, -448, -148, 7, -279, -921, -1421, -1277, -517, 156,
                -115, -1497, -3036, -3151, -827, 3392, 7483, 9175)


def fir_coeffs():
    """把 33 个折叠系数对称展开成 65 抽头。"""
    half = FIR_COEF_Q15
    assert len(half) == 33, "expected 33 folded coefficients, got %d" % len(half)
    h = np.zeros(TAPS, dtype=np.int64)
    for m in range(TAPS):
        h[m] = half[m] if m <= 32 else half[TAPS - 1 - m]
    return h


def fir_q15(x, h):
    """fir_bandpass.v：65 抽头，累加后 (acc>>15) 带饱和。返回 (y, 有效起点)。"""
    acc = np.convolve(x.astype(np.int64), h)          # 精确整数卷积
    y = acc >> 15
    y = np.clip(y, -32768, 32767)
    return y


def clt_curve(y, prepend=0):
    """clt_qrs.v：x2 = 2 + 4*|x[n]-x[n-1]|，21 点滑窗和。"""
    d = np.abs(np.diff(y.astype(np.int64), prepend=prepend))
    x2 = C_CONST + (d << 2)
    cs = np.concatenate([[0], np.cumsum(x2)])
    w = CLT_W
    clt = np.empty_like(x2)
    for n in range(len(x2)):
        a = n - w + 1
        clt[n] = cs[n + 1] - (cs[a] if a >= 0 else 0)
    return clt, x2


def detect(y, clt, y_off=0):
    """clt_qrs.v 检测状态机（含长 RR 间隙恢复阈值，与 RTL 逐条对应）。"""
    n_s = len(clt)
    peaks, amps = [], []
    learn_max = 0
    thr = est = run_max = win_max = 0
    thr_init = 0
    armed = 0
    refract = 0
    rel_cnt = 0
    last_peak_index = 0
    rr_est = 0
    rr_est_valid = False
    peak_seen = False
    for n in range(n_s):
        c = int(clt[n])
        search_lo = max(0, n - SEARCH)
        segment = y[search_lo:n + 1]
        j = int(np.argmax(segment))
        best_val = int(segment[j])
        best_off = (n - search_lo) - j
        candidate_index = n - best_off

        peak_cond = armed and (c < (run_max >> 1))
        detect_now = (n >= LEARN) and thr_init and (refract == 0) and peak_cond
        est_nxt = (3 * est + run_max) >> 2
        thr_nxt = (est_nxt * THR_NUM) >> TH_OFF
        thr_low = (est * LOW_THR_NUM) >> TH_OFF
        since_last_peak = candidate_index - last_peak_index
        recovery_start = (rr_est >> 1) if rr_est_valid else REFRACT
        recovery_end = (rr_est + (rr_est >> 1)) if rr_est_valid else RR_MAX
        recovery_window = (
            peak_seen and refract == 0
            and since_last_peak >= recovery_start
            and since_last_peak <= recovery_end
        )
        arm_threshold = thr_low if recovery_window else thr

        # 重学：win_max 也封顶 1.5 倍，est/thr 用同一个值
        cap15 = (est + (est >> 1)) if est > 0 else win_max
        win_cap = min(win_max, cap15)
        est_relearn = (est + win_cap) >> 1
        thr_relearn = (est_relearn * THR_NUM) >> TH_OFF

        if refract != 0:
            refract -= 1

        if n < LEARN:
            learn_max = max(learn_max, c)
        elif not thr_init:
            thr = (learn_max * THR_NUM) >> TH_OFF
            est = learn_max
            thr_init = 1
            armed = 0
            run_max = 0
        elif refract == 0:
            if detect_now:
                peaks.append(candidate_index)
                amps.append(best_val)
                old_run_max = run_max
                armed = 0
                run_max = 0
                refract = REFRACT
                if peak_seen and candidate_index >= last_peak_index:
                    rr_new = candidate_index - last_peak_index
                    if RR_MIN <= rr_new <= RR_MAX:
                        if not rr_est_valid:
                            rr_est = rr_new
                            rr_est_valid = True
                        else:
                            rr_est = (3 * rr_est + rr_new) >> 2
                last_peak_index = candidate_index
                peak_seen = True
                # 快攻 + 1.5 倍封顶
                if old_run_max > est:
                    est = (min(old_run_max, est + (est >> 1))
                           if est > 0 else old_run_max)
                else:
                    est = est_nxt
                thr = thr_nxt
            elif c > arm_threshold:
                if c > run_max:
                    run_max = c
                    armed = 1
            elif c < (run_max >> 1):
                # 只有跌到峰值一半以下才解除 armed（修"峰起了却确认不了"）
                armed = 0

        if REL_PERIOD > 0:
            if rel_cnt == REL_PERIOD - 1:
                est = est_relearn
                thr = thr_relearn
                win_max = c
                rel_cnt = 0
            else:
                rel_cnt += 1
                win_max = max(win_max, c)

    return np.array([p + FIR_DELAY for p in peaks], dtype=np.int64), np.array(amps)


# ---------------------------------------------------------------- 上层
def resample_fast(x, fs_in, fs_out, taps=33):
    """和 make_coe.resample_sinc 同算法，但用向量化实现（结果一致，快很多）。"""
    ratio = fs_out / fs_in
    n = int(np.floor(len(x) * ratio))
    t = np.arange(n) / ratio
    half = taps // 2
    d = np.arange(-half, half + 1)
    w = np.sinc(d) * (0.5 + 0.5 * np.cos(np.pi * d / half))
    base = np.floor(t).astype(np.int64) - half
    y = np.zeros(n, dtype=np.float64)
    wsum = np.zeros(n, dtype=np.float64)
    for k in range(taps):
        idx = np.clip(base + k, 0, len(x) - 1)
        ok = ((base + k) >= 0) & ((base + k) < len(x))
        y += w[k] * x[idx] * ok
        wsum += w[k] * ok
    return y / np.where(wsum == 0, 1.0, wsum)


def run_record(db, rec, scale=5.0):
    ch0, _ = MC.read_dat(pathlib.Path(db) / ("%s.dat" % rec))
    xs = resample_fast(ch0.astype(np.float64) * scale, FS_IN, FS_OUT)
    x = np.round(xs).astype(np.int64)
    x = np.clip(x, -32768, 32767).astype(np.int64)
    h = fir_coeffs()
    xn = notch_q15(x)
    yf_full = fir_q15(xn, h)
    yf = yf_full[TAPS - 1:]          # 丢掉 65 抽头滤波器前 64 个"未填满"的输出
    clt, _ = clt_curve(yf, prepend=0)
    peaks, amps = detect(yf, clt)
    return peaks, amps, x


def _parse_atr(path, aux_delta):
    """自己解析一遍标注（make_coe 的那份用于生成 ROM，这里要能试 aux_delta）。"""
    d = pathlib.Path(path).read_bytes()
    i = t = 0
    out = []
    while i + 1 < len(d):
        b0, b1 = d[i], d[i + 1]
        i += 2
        at, iv = b1 >> 2, ((b1 & 0x03) << 8) | b0
        if at == 59:                     # SKIP
            continue
        if at in (60, 61, 62):           # NUM / SUB / CHN
            continue
        if at == 63:                     # AUX: 跳过字符串
            i += iv + aux_delta
            continue
        t += iv
        if 1 <= at <= 13:                # 只统计"心搏"类标注
            out.append(t)
    return np.array(out, dtype=np.int64)


def truth_beats(db, rec, x=None, scale=FS_OUT / FS_IN):
    """标注时间轴：AUX(63) 的跳过长度在各文件里有 ±1 字节差异。
    判据（决定性）：正确的解析应该把**整条记录用完** —— 最后一个标注的时间
    最接近 .hea 里记录的总长度；解析错位的版本会提前"跑完"文件。
    再用"与信号 R 峰的对齐率"作为辅助判据。"""
    path = pathlib.Path(db) / ("%s.atr" % rec)
    nsamp = 650000
    hea = pathlib.Path(db) / ("%s.hea" % rec)
    if hea.exists():
        try:
            nsamp = int(hea.read_text().splitlines()[0].split()[3])
        except Exception:
            pass
    if x is None:
        beats = _parse_atr(path, 0)
    else:
        ax = np.abs(x.astype(np.int64))
        best, beats, frac_best = None, None, 0.0
        for dd in (-1, 0, 1, 2):
            ts = _parse_atr(path, dd)
            if len(ts) < 5:
                continue
            k = np.linspace(0, len(ts) - 1, min(200, len(ts))).astype(int)
            ok = tot = 0
            for j in k:
                t = int(round(int(ts[j]) * scale))      # 标注时间 -> 250 Hz 域
                lo, hi = max(0, t - 60), min(len(ax), t + 61)
                if hi <= lo:
                    continue
                p = lo + int(np.argmax(ax[lo:hi]))
                tot += 1
                if abs(p - t) <= 30:
                    ok += 1
            frac = ok / tot if tot else 0.0
            # 主判据：末标注时间离记录总长有多近（越小越好，且不许超出太多）
            over = max(0, int(ts[-1]) - nsamp)
            miss = abs(int(ts[-1]) - nsamp)
            key = (over > 20000, miss, -frac)      # 明显超长的排最后
            if best is None or key < best:
                best, beats, frac_best = key, ts, frac
    return (np.array(sorted(int(round(t * scale)) for t in beats), dtype=np.int64),
            frac_best)


def score(det, tru, tol_samples):
    """标准做法：一个检出点如果落在某个标注的 ±tol 内就算命中。"""
    used = np.zeros(len(tru), dtype=bool)
    tp = fp = 0
    for p in det:
        j = np.searchsorted(tru, p)
        best, bj = None, -1
        for k in (j - 1, j, j + 1):
            if 0 <= k < len(tru) and not used[k]:
                dd = abs(int(tru[k]) - int(p))
                if dd <= tol_samples and (best is None or dd < best):
                    best, bj = dd, k
        if bj >= 0:
            used[bj] = True
            tp += 1
        else:
            fp += 1
    fn = int((~used).sum())
    se = 100.0 * tp / (tp + fn) if (tp + fn) else 0.0
    ppv = 100.0 * tp / (tp + fp) if (tp + fp) else 0.0
    return tp, fn, fp, se, ppv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--records", default="100,101,103,105,108,111,112,114,116,117,"
                                        "118,119,121,122,123,200,208,220,223,228,230,233,234")
    ap.add_argument("--out", default="validation_report.md")
    ap.add_argument("--check100", action="store_true", help="先做 record 100 自校验")
    a = ap.parse_args()

    tol = int(round(TOL * FS_OUT))

    if a.check100:
        peaks, _, _ = run_record(a.db, "100")
        print("record 100 检出前 8 个峰:", peaks[:8].tolist())
        print("RTL 仿真结果       :  [54, 258, 461, 658] （ROM 前 711 点内）")
        return

    recs = [r.strip() for r in a.records.split(",") if r.strip()]
    rows = []
    for rec in recs:
        try:
            det, _, x = run_record(a.db, rec)
            tru, align = truth_beats(a.db, rec, x=x)
            tp, fn, fp, se, ppv = score(det, tru, tol)
            ok = align >= 0.90            # 参考标注时间轴是否可信
            rows.append((rec, len(tru), tp, fn, fp, se, ppv, align, ok))
            print("%-5s 标注%5d  TP%5d FN%4d FP%5d  Se=%6.2f%%  PPV=%6.2f%%  对齐%5.1f%%%s"
                  % (rec, len(tru), tp, fn, fp, se, ppv, 100 * align,
                     "" if ok else "   <-- 参考时间轴不可信，仅列出"))
        except Exception as e:                      # noqa
            print("%-5s 失败: %s" % (rec, e))

    good = [r for r in rows if r[8]]
    if good:
        tp = sum(r[2] for r in good); fn = sum(r[3] for r in good); fp = sum(r[4] for r in good)
        se = 100.0 * tp / (tp + fn); ppv = 100.0 * tp / (tp + fp)
        print("-" * 66)
        print("可信记录 %d/%d 条：TP=%d FN=%d FP=%d   总 Se=%.2f%%  总 PPV=%.2f%%"
              % (len(good), len(rows), tp, fn, fp, se, ppv))
        lines = ["| 记录 | 标注心搏 | 检出TP | 漏检FN | 误检FP | Se(%) | PPV(%) | 参考时间轴可信 |",
                 "|---|---|---|---|---|---|---|---|"]
        for r in rows:
            lines.append("| %s | %d | %d | %d | %d | %.2f | %.2f | %s |"
                         % (r[0], r[1], r[2], r[3], r[4], r[5], r[6],
                            "✅" if r[8] else "❌ 仅列出"))
        lines.append("| **合计（仅可信记录）** | %d | %d | %d | %d | **%.2f** | **%.2f** | |"
                     % (sum(r[1] for r in good), tp, fn, fp, se, ppv))
        pathlib.Path(a.out).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("表格已写入 %s" % a.out)


if __name__ == "__main__":
    main()
