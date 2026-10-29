# -*- coding: utf-8 -*-
"""
pvc_check.py —— FPGA 采完的数据里，把心搏分成「正常 / 室早 / 房早」

用法（板子的 Jupyter 里，和 ecg_bd_wrapper.bit 放同一个文件夹）：

    %run pvc_check.py

它会：读一次采集缓存 → 逐拍算特征 → 按规则判别 → 画图 + 打一张表。

为什么要单独做这一步：
    PL 里的 CLT 检测器是「按 CLT 峰值 + 自适应阈值」判 R 峰的，
    而室早的特点是"宽大畸形、斜率反而更小"——CLT 峰值可能低于正常搏动，
    于是会被漏掉。所以这里做两级：
        第一级：信 FPGA 的 R 标志（高灵敏、不漏正常搏动）
        第二级：在波形上补找"漏掉的"搏动，再用形态学规则重新分类
    这正是"PL 粗检 + PS 复核"的两级结构。

判据（都在下面 CONFIG 里，可调）：
    宽大  —— QRS 宽度 > 120 ms，或 > 1.35 × 正常参考宽度
    提前  —— RR < 0.80 × 中位 RR
    室早  = 宽大            （临床上室早的标志就是 QRS 又宽又丑）
    房早  = 提前 但 不宽    （提前出现、形态正常）
    其余  = 正常
"""

import time

import numpy as np

try:
    from pynq import Overlay, MMIO          # 板子上有；离线自测时走 except
except Exception:                            # pragma: no cover
    Overlay = MMIO = None

BITFILE = "ecg_bd_wrapper.bit"
FS = 250.0                                   # 采样率

# ---------------------------------------------------------------- 可调参数
GAP_S       = 0.16    # 两拍之间至少隔这么久（秒），防止一个 QRS 数成两个
WIDE_MS     = 120.0   # QRS 宽于这个 → 形态"宽大"（室早的典型特征）
WIDE_RATIO  = 1.35    # 或者比"正常参考宽度"宽这么多倍
EARLY_RATIO = 0.80    # RR 短于中位 RR 的这个比例 → "提前"
MISS_AMP    = 0.45    # 补找漏检时，幅度要超过 R 幅度中位数的这个比例
THR_FRAC    = 0.25    # 量 QRS 宽度时，用到峰值的这个比例作为"出波"门限

# ---- 信号质量判据（先判断"到底有没有接人"，再谈分类）----
#   检测器只认"尖峰"，分不清心跳和电路打摆/干扰，所以要先过这一关。
Q_AMP_FRAC  = 0.15    # 峰值 > 满量程的 15% → 无效
Q_BIAS_FRAC = 0.25    # |中位数| > 峰值的 25% → 无效（方波/单边特征）
Q_EXT_FRAC  = 0.50    # 一半以上时间贴在极值附近 → 无效（方波特征）


def signal_quality(wave):
    """返回 (是否有效, 命中的原因列表, 指标)。"""
    w = np.asarray(wave).astype(np.int64)
    amp = int(np.abs(w).max()) if len(w) else 0
    med = float(np.median(w)) if len(w) else 0.0
    half = max(1.0, (int(w.max()) - int(w.min())) / 2.0) if len(w) else 1.0
    frac_ext = float(np.mean(np.abs(w - med) > 0.6 * half)) if len(w) else 0.0
    bad = []
    if amp > Q_AMP_FRAC * 32768:
        bad.append("幅度过大（峰值 %d 计数）" % amp)
    if amp > 0 and abs(med) > Q_BIAS_FRAC * amp:
        bad.append("基线严重偏移（中位数 %+.0f，峰值的 %.0f%%）" % (med, abs(med) / amp * 100))
    if frac_ext > Q_EXT_FRAC:
        bad.append("长时间贴上下限（%.0f%% 时间在极值附近，像方波）" % (frac_ext * 100))
    return (len(bad) == 0), bad, dict(amp=amp, med=med, frac_ext=frac_ext)


# ---------------------------------------------------------------- 读缓存
def _mm():
    ol = Overlay(BITFILE)
    return MMIO(ol.ip_dict["ecg_axil_0"]["phys_addr"], 0x1000)


def capture(n_samples=711, src=0, timeout=None):
    """抓一段数据，返回 (wave, clt, rflag)。和 pynq_ecg.py 里的同名函数一致。"""
    mm = _mm()
    n = int(max(1, min(n_samples, 2048)))
    src_bit = 0x04 if src else 0x00
    mm.write(0x24, n)
    mm.write(0x00, 0x02 | src_bit)           # soft_rst：清缓存、清检测器
    time.sleep(0.05)
    mm.write(0x00, 0x01 | src_bit)           # run = 1
    if timeout is None:
        timeout = n / FS + 2.0
    t0 = time.time()
    while (mm.read(0x04) & 0x02) == 0:       # 等 cap_done
        if time.time() - t0 > timeout:
            print("!! 等 cap_done 超时")
            break
        time.sleep(0.02)
    time.sleep(0.05)
    words = np.zeros(2 * n + 1, dtype=np.uint32)
    for k in range(2 * n + 1):
        mm.write(0x30, k)
        words[k] = mm.read(0x34)
    return decode(words, n)


def decode(words, n):
    """缓存格式：地址 0 空；奇数地址 = 波形字(bit16=R标志)；偶数地址 = CLT。"""
    odd = words[1::2].astype(np.int64)
    raw = (odd & 0xFFFF).astype(np.int64)
    wave = np.where(raw >= 0x8000, raw - 0x10000, raw).astype(np.int64)[:n]
    flag = ((odd >> 16) & 1).astype(np.int64)[:n]
    # 2026-10-18: 新版比特流把"导联状态有效"标志放在 CLT 字的 bit31、
    # 导联状态字节放在 bit30:24，所以这里必须只取低 24 位，
    # 否则 CLT 整条曲线会被抬高 2.147e9（之前就是这个问题）。
    clt = (words[2::2].astype(np.int64) & 0x00FFFFFF)[:n]
    return wave, clt, flag


# ---------------------------------------------------------------- 找心搏
def find_beats(wave, rflag):
    """第一级信 R 标志；第二级在波形上补找漏掉的搏动。返回下标数组。"""
    a = np.abs(wave.astype(np.int64))
    gap = max(3, int(GAP_S * FS))
    beats = []
    # --- 第一级：FPGA 给的 R 标志，往前找 25 点内的波形极值当真正的峰 ---
    for p in np.where(rflag == 1)[0]:
        lo = max(0, p - 25)
        beats.append(lo + int(np.argmax(a[lo:p + 1])))
    # --- 第二级：波形上"够大"的局部极值，且离已有搏动够远 ---
    thr = MISS_AMP * (np.median(a[beats]) if beats else a.max())
    i = 0
    while i < len(a):
        if a[i] > thr:
            j = min(len(a), i + gap)
            k = i + int(np.argmax(a[i:j]))
            if all(abs(k - b) > gap for b in beats):
                beats.append(k)
            i = k + gap
        else:
            i += 1
    return np.array(sorted(beats), dtype=int)


def beat_features(wave, pk):
    """量一个搏动：幅度、QRS 宽度（点数）、"能量面积"、起止下标。"""
    a = np.abs(wave.astype(np.int64))
    amp = int(a[pk])
    thr = max(3.0, THR_FRAC * amp)
    lo = hi = pk
    while lo > 0 and a[lo - 1] > thr:
        lo -= 1
    while hi < len(a) - 1 and a[hi + 1] > thr:
        hi += 1
    return dict(peak=pk, amp=amp, width=hi - lo + 1,
                area=int(a[lo:hi + 1].sum()), lo=lo, hi=hi)


def classify(wave, rflag):
    """返回 (逐拍结果列表, 参考宽度, 参考RR)。"""
    beats = find_beats(wave, rflag)
    feats = [beat_features(wave, int(p)) for p in beats]
    if len(feats) == 0:
        return [], None, None

    widths = np.array([f["width"] for f in feats], dtype=float)
    rrs = np.array([feats[i]["peak"] - feats[i - 1]["peak"]
                    for i in range(1, len(feats))], dtype=float)
    # 参考"正常"宽度：取较窄的那一半（假设正常搏动占多数）
    half = max(2, int(np.ceil(len(widths) / 2.0)))
    ref_w = float(np.median(np.sort(widths)[:half]))
    ref_rr = float(np.median(rrs)) if len(rrs) else 0.0

    out = []
    for i, f in enumerate(feats):
        rr = feats[i]["peak"] - feats[i - 1]["peak"] if i > 0 else None
        wide = (f["width"] > WIDE_RATIO * ref_w) or (f["width"] / FS * 1000.0 > WIDE_MS)
        early = (rr is not None) and ref_rr > 0 and (rr < EARLY_RATIO * ref_rr)
        if wide:
            label = "室早"
            why = "QRS 宽 %.0f ms（正常参考 %.0f ms）" % (
                f["width"] / FS * 1000.0, ref_w / FS * 1000.0)
            if early:
                why += " + 提前"
        elif early:
            label = "房早/室上早"
            why = "提前（RR %d < %.2f×中位 %.0f）" % (rr, rr / ref_rr, ref_rr)
        else:
            label = "正常"
            why = ""
        out.append(dict(f, t=f["peak"] / FS, rr=rr, label=label, why=why))
    return out, ref_w, ref_rr


# ---------------------------------------------------------------- 输出
def show_result(wave, clt, beats, title="", save=None):
    import matplotlib.pyplot as plt
    # 汇报版样式：字大、线粗、不画网格（截图直接能用）
    plt.rcParams.update({
        "font.size": 12, "axes.titlesize": 13, "axes.labelsize": 12,
        "xtick.labelsize": 11, "ytick.labelsize": 11, "legend.fontsize": 10,
    })
    t = np.arange(len(wave)) / FS
    fig, ax = plt.subplots(2, 1, figsize=(12, 7), sharex=True)
    # NOTE: the labels/title of the *figure* are kept in English on purpose -
    # the PYNQ image has no CJK font for matplotlib, so Chinese text in a plot
    # comes out as empty boxes (plus a flood of "Glyph missing" warnings).
    # The printed table below stays in Chinese (Jupyter renders that fine).
    ax[0].plot(t, wave, lw=1.1, color="#1f77b4", label="filtered ECG")
    colors = {"正常": "#2ca02c", "室早": "#d62728", "房早/室上早": "#ff7f0e"}
    names = {"正常": "normal", "室早": "PVC", "房早/室上早": "PAC"}
    for lab in ("正常", "室早", "房早/室上早"):
        idx = [b["peak"] for b in beats if b["label"] == lab]
        if idx:
            ax[0].plot(t[idx], wave[idx], "v", ms=11, color=colors[lab], label=names[lab])
    ax[0].grid(alpha=0.15, lw=0.5)
    ax[0].legend(loc="upper right", frameon=True, facecolor="white",
                 framealpha=0.9, edgecolor="none")
    ax[0].set_ylabel("ADC counts")
    ax[0].set_title("%s   beats=%d  normal=%d  PVC=%d  PAC=%d" % (
        title, len(beats),
        sum(1 for b in beats if b["label"] == "正常"),
        sum(1 for b in beats if b["label"] == "室早"),
        sum(1 for b in beats if b["label"] == "房早/室上早")))
    ax[1].plot(t, clt, lw=1.1, color="#2ca02c")
    ax[1].set_ylabel("CLT"); ax[1].set_xlabel("time (s)")
    ax[1].grid(alpha=0.15, lw=0.5)
    plt.tight_layout()
    if save:
        plt.savefig(save, dpi=120)
    plt.show()


def print_table(beats, ref_w, ref_rr):
    print("-" * 76)
    print("  序号   时间(s)   RR(点)   幅度    QRS宽度  判定      依据")
    print("-" * 76)
    for i, b in enumerate(beats):
        print("  %3d   %6.2f   %6s   %6d   %4d 点   %-8s %s" % (
            i, b["t"], "-" if b["rr"] is None else b["rr"], b["amp"],
            b["width"], b["label"], b["why"]))
    print("-" * 76)
    print("  参考值：正常 QRS 宽度 ≈ %.0f ms（%d 点）；中位 RR ≈ %.0f 点（%.0f bpm）" % (
        ref_w / FS * 1000.0, int(ref_w),
        0 if ref_rr is None else ref_rr,
        0 if not ref_rr else 60.0 * FS / ref_rr))
    n_pvc = sum(1 for b in beats if b["label"] == "室早")
    print("  结论：共 %d 拍，其中室早 %d 次" % (len(beats), n_pvc))


if __name__ == "__main__":
    wave, clt, rflag = capture(711, src=0)
    ok, reasons, m = signal_quality(wave)
    if not ok:
        print("!! 信号无效：这一段不像心电（判定为【电极未接 / 输入过载】），先不做分类")
        for r in reasons:
            print("   - " + r)
        print("   （检测器本身没问题：它只认尖峰，分不清心跳和干扰。）")
    else:
        beats, ref_w, ref_rr = classify(wave, rflag)
        if len(beats) == 0:
            print("没找到心搏：先确认数据是否采到（参考 check_ads1292.py 的结果）")
        else:
            print("信号质量：通过（幅度 %d 计数，基线 %+.0f）" % (m["amp"], m["med"]))
            print_table(beats, ref_w, ref_rr)
            show_result(wave, clt, beats, title="PVC check (ROM)")


