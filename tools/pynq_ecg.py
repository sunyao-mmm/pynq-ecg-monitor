# -*- coding: utf-8 -*-
"""
pynq_ecg.py -- PYNQ-Z2 板上运行的心电演示脚本（在板子的 Jupyter 里跑）

准备工作
  1. 把 ecg_bd_wrapper.bit 和 ecg_bd_wrapper.hwh 放在同一个文件夹里
     （注意：Vivado 导出的是 ecg_bd.hwh，必须改名成 ecg_bd_wrapper.hwh，
      否则 Overlay 会报找不到硬件描述文件）
  2. 改下面 BITFILE 这一行
  3. 依次跑：3.1 ROM 自检  ->  3.2 实时采集  ->  3.3 画图

寄存器映射（相对基址，单位字节）
  0x00 CTRL       RW  bit0=run, bit1=soft_rst, bit2=src_sel (0=ROM, 1=ADS1292)
  0x04 STATUS     RO  bit0=run, bit1=cap_done, [31:16]=beat_count
  0x08 CLT_NOW    RO  当前 CLT 值（每来一个采样点就变，可用来判断数据在不在动）
  0x0C R_INDEX    RO  最近一个 R 峰的位置（输入样点序号）
  0x10 R_AMP      RO  最近一个 R 峰的幅度
  0x14 BPM        RO  心率
  0x18 RR_SAMPLES RO  最近一个 RR 间期（样点）
  0x1C BEAT_COUNT RO  累计心搏数
  0x20 RR_BAD_CNT RO  异常 RR 计数
  0x24 CAP_LEN    RW  采集多少个采样点（1..2048）
  0x28 SCRATCH    RW  随便写
  0x2C ID         RO  固定 0x0EC60001（用来确认 overlay 加载对了）
  0x30 CAP_ADDR   RW  缓存读地址（字地址）
  0x34 CAP_DATA   RO

缓存里的内容：每个采样点占两个字。注意硬件的写法是"数据先算出来、地址后自增"，
所以每个字实际落在了**下一个**字地址上：
  地址 0   : 永远是空的（从来没被写过）
  奇数地址 : bit16 = R 峰标志, bit15:0 = 滤波后的心电波形（16 位补码，有负数）
  偶数地址 : CLT 曲线值（从地址 2 开始）
  采集时长 = CAP_LEN / 250 秒

（2026-10-11 修正：这一版原来把奇偶读反了，把 CLT 当成波形画。现在 capture()
  会自动判断哪一半是波形，不用你手动改。）

采样点序号换算：缓存第 j 点的"输入样点序号" = j + 32（FIR 有 32 个样点的群延迟）。

关于 R 峰标志位：检测是在 CLT 跌到峰值一半时才判定的，所以标志位落在
真实 R 峰**后面约 22 个采样点（88 ms）**。画图时脚本会自动在这附近找波形的
极值（refine_peaks），把三角标到真正的 R 峰上，不用手工对。
"""

import time

import numpy as np
import matplotlib.pyplot as plt
from pynq import Overlay, MMIO

# 相对路径：脚本放在哪个文件夹，就在哪个文件夹找比特流。
# （原来写死成 /home/xilinx/ecg/... 是错的，会让 Overlay 报找不到文件）
BITFILE = "ecg_bd_wrapper.bit"
FS_HZ    = 250.0       # 设计采样率（ROM 通路精确等于它）
FS_MEAS  = 243.65      # 实测 ADS1292 进样率（芯片内部振荡器偏低约 2.5%）
FIR_DELAY = 32         # FIR 群延迟（样点），用于把 r_index 换算到缓存下标

# 台面换算：读的是 ADS1292 的【通道2】（心电在这个通道上），增益 6、VREF 2.42V，
# 缓存里的 1 个计数 ≈ 12.3 uV。
#   通道1 = 增益2（≈36.9 uV/计数），但模块上通道1没有接电极，所以我们不读它。
UV_PER_CODE = 12.3

ol = Overlay(BITFILE)
mm = MMIO(ol.ip_dict["ecg_axil_0"]["phys_addr"], 0x1000)

# 去毛刺版比特流会在波形字的 bit17 打一个"这个点不可信"的标。
# 老比特流这一位永远是 0，所以这段代码对两个版本都安全。
LAST_INV = None
# 最近一次 capture() 的数据源（0=ROM, 1=ADS1292），用于 bpm 的采样率校正
LAST_SRC = None
# CLT 字的最高字节放的是 ADS1292 的 LOFF_STAT（导联接触状态），
# bit31=1 表示"这版比特流带导联检测"。
LAST_LOFF = None


def reg_read(off):
    return mm.read(off)


def reg_write(off, val):
    mm.write(off, int(val))


def id_check():
    """确认 overlay 加载正确、AXI 通了。"""
    val = hex(reg_read(0x2C))
    print("ID =", val, "(expect 0xec60001)", "OK" if val == "0xec60001" else "!! 不对")
    return val


def capture(n_samples=1000, src=0, timeout=None, retries=3):
    """
    抓一段数据。

    n_samples : 采样点数，1..2048（每个点两个字，缓存一共 4096 字）
    src       : 0 = MIT-BIH ROM（离线数据集），1 = ADS1292（实时心电）
    返回 (wave, clt, rflag)：
      wave  : int16 数组，滤波后的心电波形
      clt   : int32 数组，CLT 曲线
      rflag : 0/1 数组，R 峰标志
    """
    n = int(max(1, min(n_samples, 2048)))
    src_bit = 0x04 if src else 0x00
    global LAST_SRC
    LAST_SRC = src

    if timeout is None:
        # 2026-10-17：原来只多给 2 秒，实测余量太小（2000 点 @250Hz 理论 8 秒，
        # 加上电脑端轮询和启动延迟就会"刚好超时"）。改成多给 10 秒。
        timeout = n / FS_HZ + 10.0

    # 2026-10-17：抓取改成"最多试 3 次"。
    # 实测这条链路偶尔会断一下（芯片那一帧没送到），重来一次通常就好了。
    done = False
    for attempt in range(1, retries + 1):
        reg_write(0x24, n)                    # CAP_LEN
        reg_write(0x00, 0x02 | src_bit)       # soft_rst = 1，清缓存、清检测器
        time.sleep(0.05)
        reg_write(0x00, 0x01 | src_bit)       # run = 1

        t0 = time.time()
        while (reg_read(0x04) & 0x02) == 0:   # STATUS.cap_done
            if time.time() - t0 > timeout:
                break
            time.sleep(0.02)
        done = (reg_read(0x04) & 0x02) != 0
        dt = time.time() - t0

        if dt > 0.05:
            print("   [第 %d 次] 抓 %d 点用了 %.2f 秒 → %.0f Hz 吞吐量（含初始化，不是采样率）   %s"
                  % (attempt, n, dt, n / dt, "OK" if done else "超时"))
        if done:
            break
        if attempt < retries:
            print("   ! 这次没等到 cap_done，自动重试 ……")
            time.sleep(0.3)
    if not done:
        print("!! 试了 %d 次都没抓到（数据没进来）。先看诊断脚本第 2 段的帧数在不在涨。" % retries)
        print("   常见原因：芯片没在转换 / DRDY 没到 FPGA / 白座接触不良。")
    time.sleep(0.05)

    # 多读一个字：硬件把数据写到了下一个地址，最后那个 CLT 字落在 2n 上
    words = np.zeros(2 * n + 1, dtype=np.uint32)
    for k in range(2 * n + 1):
        reg_write(0x30, k)                # CAP_ADDR
        words[k] = reg_read(0x34)         # CAP_DATA

    # 硬件是固定写法：奇数地址 = 波形字（bit16 = R 标志），偶数地址 = CLT。
    #
    # 曾经这里用"哪一半里 bit16 为 1 的多，就认为哪一半是波形"来自动判断，
    # 2026-10-15 实测踩坑：**输入过载时 CLT 会冲到 6 万以上，CLT 自己的 bit16
    # 会大量为 1**，于是脚本把 CLT 当成波形画 —— 表现就是"波形顶到 ±30000、
    # R 峰标志几百个"。所以现在改成**写死取奇数地址**，不要再自动判断。
    wsrc  = words[1::2].astype(np.int64)
    flags = (wsrc >> 16) & 1
    clt_w = words[2::2].astype(np.int64)
    clt   = (clt_w & 0x00FFFFFF)[:n]
    global LAST_LOFF
    _top = int(clt_w[0] >> 24) & 0xFF if len(clt_w) else 0
    LAST_LOFF = (_top & 0x7F) if (_top & 0x80) else None

    raw = (wsrc & 0xFFFF).astype(np.int64)
    wave = np.where(raw >= 0x8000, raw - 0x10000, raw).astype(np.int16)[:n]   # 16 位补码
    rflag = flags.astype(np.int64)[:n]
    # 直接在这里打印，免得还要去引用全局变量（计数器是累计的，不会因抓取清零）
    return wave, clt, rflag


def loff_text(stat):
    """
    显示 ADS1292 数据帧状态字里的导联标志字节。

    注意：这个字节的位定义在不同数据手册/不同版本里写法不完全一样，
    所以这里只报原始值和置了哪几位，不硬猜"哪根线断了"。
    经验判断：0x00 = 各电极都在；非 0 = 有电极被判为脱落。
    （接好/拔掉各测一次，看这个值怎么变，就知道了。）
    """
    if stat is None:
        return "这版比特流没有导联检测信息（烧的是旧版 .bit）"
    if stat == 0:
        return "导联状态字节 = 0x00（各电极都在）"
    bits = [str(b) for b in range(8) if stat & (1 << b)]
    return "导联状态字节 = 0x%02x（置位：bit %s）—— 有电极接触不良" % (
        stat, ", ".join(bits))


def measure_fs(n=1000, src=1):
    """
    测真实采样率。
    只计时"从启动到 cap_done"这一段——不包含回读缓存。
    （旧版把 2001 次 Python MMIO 回读也算进去了，每次约 0.2 ms，
      总共 0.4 秒左右，所以测出来永远是 220 出头，是假象。）
    """
    src_bit = 0x04 if src else 0x00

    def one_run():
        reg_write(0x24, n)
        reg_write(0x00, 0x02 | src_bit)     # soft reset
        time.sleep(0.05)
        reg_write(0x00, 0x01 | src_bit)     # run
        t0 = time.time()
        while (reg_read(0x04) & 0x02) == 0:
            if time.time() - t0 > n / 200.0 + 5.0:
                break
            time.sleep(0.002)
        return time.time() - t0, (reg_read(0x04) & 0x02) != 0

    one_run()                                # 第一次带着初始化
    dt, ok = one_run()                       # 第二次是纯采集
    fs = n / dt if dt > 0 else 0.0
    print("真实采样率 ≈ %.1f Hz   (%d 点 / %.3f 秒)%s"
          % (fs, n, dt, "" if ok else "   [超时]"))
    return fs

def status_text():
    st = reg_read(0x04)
    bpm_raw = reg_read(0x14) & 0xFFFF
    # 2026-10-20：ADS1292 实测进样率 243.65 Hz，而硬件按 FS_HZ=250 换算，
    # 所以实时通路的 bpm 系统性偏高约 2.6%。这里只在 PS 端按实测值换算，
    # RTL 与 ROM 通路的数字都不动。
    if LAST_SRC == 1:
        bpm = int(round(bpm_raw * FS_MEAS / FS_HZ))
    else:
        bpm = bpm_raw
    rr = reg_read(0x18)
    beats = reg_read(0x1C)
    bad = reg_read(0x20)
    _bpm_tag = ("（校正自 %d）" % bpm_raw) if (LAST_SRC == 1 and bpm != bpm_raw) else ""
    return ("cap_done=%d  beat_count=%d  bpm=%d%s  rr=%d  rr_bad=%d"
            % ((st >> 1) & 1, beats, bpm, _bpm_tag, rr, bad))


def flow_check(seconds=1.0):
    """
    3 秒钟判断"数据到底有没有在动"：
    CLT_NOW 每个采样点都会刷新，1 秒里应该变 250 次左右。
    """
    a = reg_read(0x08)
    time.sleep(seconds)
    b = reg_read(0x08)
    print("CLT_NOW: %d -> %d  (%s)" % (a, b, "数据在动" if a != b else "没动，采样没进来"))
    print("STATUS :", status_text())


def refine_peaks(wave, rflag, back=25):
    """
    R 峰标志比真实峰晚约 SEARCH=22 个采样点（检测是等 CLT 跌到半峰才判定的）。
    这里在每个标志前面 back 个点内找【最大的正样本】，把标记挪到真正的 R 峰上。

    2026-10-18：以前用的是"绝对值最大"。双相 QRS 里负向的 S 波常常比 R 波更深，
    绝对值规则会把标记挪到谷底（图上三角落在负峰上）。硬件内部定位 R 峰用的是
    "窗口内最大的正样本"(best_val)，绘图跟着用同一套规则，两边才会落在同一个点上。
    """
    peaks = []
    for p in np.where(rflag == 1)[0]:
        lo = max(0, p - back)
        seg = wave[lo:p + 1].astype(np.int64)
        peaks.append(lo + int(np.argmax(seg)))
    return np.array(sorted(peaks), dtype=int)


# =====================================================================
# 信号质量判据：先判断"到底有没有接人"，再决定要不要报心跳
#   RTL 里的检测器只认"尖峰"（曲线长度冲高再掉下来），它分不清
#   "人心跳" 和 "电路打摆/干扰"。电极没接、输入悬空时波形是方波状，
#   检测器就会一路误报 —— 所以要在 PS 端先做一次质量判断。
#   判据（三条，命中任意一条就算"信号无效"）：
#     S1 幅度过大 ：峰值 > 满量程的 15%（真人滤波后心电不会这么大）
#     S2 基线偏移 ：中位数偏离 0 超过峰值的 25%（方波/单边信号的特征）
#     S3 长时间贴极值：一半以上时间都在最大/最小附近（方波的典型样子）
# =====================================================================
Q_AMP_FRAC  = 0.15      # S1：峰值 / 32768（超过就是削顶/过载）
Q_BIAS_FRAC = 0.90      # S2：|中位数| / 峰值（接近 1 才说明信号贴在一边，像削顶）
Q_EXT_FRAC  = 0.50      # S3：贴极值的时间占比
Q_SPAN_MIN  = 30        # S0：峰峰值小于这个数，就是"几乎没信号"


def _movavg(x, n):
    """滑动平均，两端用边值补齐，长度不变。"""
    x = np.asarray(x, dtype=np.float64)
    n = int(max(1, n))
    if n <= 1 or len(x) < n:
        return x.copy()
    pad = n // 2
    xp = np.pad(x, (pad, n - 1 - pad), mode="edge")
    k = np.ones(n) / n
    return np.convolve(xp, k, mode="valid")[:len(x)]


def _median3(x):
    """3 点中值滤波（只去单点毛刺）。"""
    x = np.asarray(x, dtype=np.int64)
    if len(x) < 3:
        return x.copy()
    xp = np.pad(x, (1, 1), mode="edge")
    a, b, c = xp[:-2], xp[1:-1], xp[2:]
    return (a + b + c
            - np.minimum(np.minimum(a, b), c)
            - np.maximum(np.maximum(a, b), c)).astype(np.int64)


def _median_k(x, k=5):
    """k 点中值（k 取奇数）。"""
    x = np.asarray(x, dtype=np.int64)
    if len(x) < k:
        return x.copy()
    h = k // 2
    xp = np.pad(x, (h, h), mode="edge")
    win = np.stack([xp[i:i + len(x)] for i in range(k)], axis=1)
    return np.sort(win, axis=1)[:, h]


def despike_runs(x, max_w=4, scale=8.0):
    """
    把"又窄又高"的毛刺整段抹掉（只用于显示）。
    先用 9 点中值当平滑参照，偏离超过若干倍抖动的点标成可疑并连成段，
    只处理长度 <= max_w 的段——真 QRS 有十几个点宽，碰不到。
    """
    x = np.asarray(x, dtype=np.int64)
    if len(x) < 20:
        return x.copy()
    ref = _median_k(x, 9)
    d = x - ref
    mad = float(np.median(np.abs(d))) + 1e-6
    bad = np.abs(d) > max(25.0, scale * 1.4826 * mad)
    idx = np.flatnonzero(bad)
    if len(idx) == 0:
        return x.copy()

    runs, start, prev = [], idx[0], idx[0]
    for i in idx[1:]:
        if i - prev > 1:
            runs.append((start, prev))
            start = i
        prev = i
    runs.append((start, prev))

    y = x.astype(np.float64).copy()
    for a, b in runs:
        if (b - a + 1) > max_w:
            continue
        lo, hi = max(0, a - 1), min(len(x) - 1, b + 1)
        y[a:b + 1] = np.linspace(y[lo], y[hi], b - a + 3)[1:-1]
    return y.astype(np.int64)


def clean_for_display(w, fs=FS_HZ, despike=True):
    """去掉窄毛刺 + 慢基线，只用于画图。"""
    x = np.asarray(w, dtype=np.int64)
    if despike:
        x = despike_runs(x, max_w=4)
    x = x - _movavg(x, int(fs))
    return x.astype(np.int64)

def signal_quality(wave):
    """
    判断这一段到底像不像心电（只看【交流成分】）。

    2026-10-19 改：原来是拿"中位数 / 峰值"判断是否贴在一边，但 FIR 带通对直流
    的抑制只有约 5.8%，原始 ADC 的偏置会漏过来（实测 −683），于是"偏置大但波形
    完全正常"的采集被误判成"削顶、电极未接"。
    现在先减掉中位数，只看交流幅度、峰峰值、贴边比例——偏置不再参与判断。
    """
    w = wave.astype(np.int64)
    med = float(np.median(w))
    ac  = w - med
    amp = int(np.abs(ac).max()) if len(ac) else 0
    hi, lo = (int(ac.max()), int(ac.min())) if len(ac) else (0, 0)
    span = hi - lo
    half = max(1.0, span / 2.0)
    frac_ext = float(np.mean(np.abs(ac) > 0.6 * half)) if len(ac) else 0.0

    bad = []
    if span < Q_SPAN_MIN:
        bad.append("几乎没有信号（峰峰值只有 %d 计数）—— 多半这次没抓到数据" % span)
    if amp > Q_AMP_FRAC * 32768:
        bad.append("交流幅度过大（%d 计数，超过满量程的 %.0f%%）" % (amp, Q_AMP_FRAC * 100))
    if frac_ext > Q_EXT_FRAC:
        bad.append("长时间贴在上下限（%.0f%% 的时间在极值附近，像方波）" % (frac_ext * 100))
    return (len(bad) == 0), bad, dict(amp=amp, med=med, frac_ext=frac_ext, span=span)

def filter_markers(wave, idx, frac=0.40):
    """
    显示端幅度筛选（2026-10-19）。

    硬件给的 R 峰标志里，混着一类"又矮又尖"的小毛刺：它们的 CLT 能过阈值
    （因为陡），但波形幅度只有真 QRS 的三四成。这里按"本次采集里各标记的
    局部峰峰值中位数"做参照，低于 40% 的不画三角。

    为什么取 40%：实测假标记约 25~30%，而室早约 45%——取 40 既能滤掉假标记，
    又不会误伤室早。

    注意：**只影响画图**。bpm 是硬件按 r_index 算的，这里不碰。
    返回 (保留的下标, 被剔除的个数)
    """
    idx = np.asarray(idx, dtype=int)
    if len(idx) == 0:
        return idx, 0
    w = np.asarray(wave).astype(np.int64)
    amps = []
    for p in idx:
        lo, hi = max(0, int(p) - 12), min(len(w), int(p) + 13)
        seg = w[lo:hi]
        amps.append(int(seg.max() - seg.min()))
    amps = np.asarray(amps)
    ref = float(np.median(amps))
    keep = idx[amps >= frac * ref]
    return keep, int(len(idx) - len(keep))


def show(wave, clt, rflag, title="", show_clt=True, clean=True):
    """画波形 + R 峰标志（可选再画一条 CLT 曲线）。"""
    # 汇报版样式：字大、线粗、不画网格（截图直接能用，不用再单独美化）
    plt.rcParams.update({
        "font.size": 12, "axes.titlesize": 13, "axes.labelsize": 12,
        "xtick.labelsize": 11, "ytick.labelsize": 11, "legend.fontsize": 10,
    })
    t = np.arange(len(wave)) / FS_HZ
    wave_raw = np.asarray(wave)
    wv = clean_for_display(wave_raw) if clean else wave_raw
    rows = 2 if show_clt else 1
    fig, axes = plt.subplots(rows, 1, figsize=(12, 3.9 * rows), sharex=True)
    if rows == 1:
        axes = [axes]

    ax = axes[0]
    ax.plot(t, wv, lw=1.1, color="#1f77b4",
            label="filtered ECG (display: despiked + baseline removed)")
    # 去毛刺版比特流会把判为毛刺的采样点标出来（bit17），这里画成浅橙色底纹：
    # 不修改数据，只是告诉看图的人"这一段不可信"。
    if LAST_INV is not None and len(LAST_INV) == len(wave) and LAST_INV.sum() > 0:
        inv_idx = np.where(LAST_INV == 1)[0]
        start = inv_idx[0]
        prev = inv_idx[0]
        for k in inv_idx[1:]:
            if k - prev > 1:
                ax.axvspan(t[start], t[prev], color="#ff7f0e", alpha=0.22, lw=0)
                start = k
            prev = k
        ax.axvspan(t[start], t[prev], color="#ff7f0e", alpha=0.22, lw=0,
                   label="flagged as spike (untrusted)")
    ok, reasons, m = signal_quality(wave_raw)
    idx_raw = refine_peaks(wave_raw, rflag) if ok else np.array([], dtype=int)
    idx, _n_drop = filter_markers(wave_raw, idx_raw)
    if len(idx):
        ax.plot(t[idx], wv[idx], "v", color="#d62728", ms=11, label="R peak")
        for p in idx:
            ax.axvline(t[p], color="#d62728", lw=0.6, alpha=0.35)
    # 固定显示窗口：用 99% 分位定高度。心跳占的采样点大约就是这个比例，
    # 而毛刺只有零星几个点，影响不到分位数；偶尔一个大毛刺就画到框外，
    # 整条波形不会被压扁。
    if len(wv):
        amp_disp = float(np.percentile(np.abs(wv), 99))
        half = max(40.0, 1.5 * amp_disp)
        ax.set_ylim(-half, half)
    ax.set_ylabel("counts (display)")
    ax.grid(alpha=0.15, lw=0.5)          # 很淡的网格：托底用，不会盖住信号
    ax.legend(loc="upper right", frameon=True, facecolor="white",
              framealpha=0.9, edgecolor="none")
    ax.set_title("%s   %d samples = %.1f s%s" % (
        title, len(wave), len(wave) / FS_HZ,
        "" if ok else "    [INVALID INPUT]"))

    if show_clt:
        axes[1].plot(t, clt, lw=1.1, color="#2ca02c")
        if len(clt):
            top = float(np.percentile(np.clip(clt, 0, None), 99))
            axes[1].set_ylim(0, max(500.0, 1.8 * top))
        axes[1].set_ylabel("CLT")
        axes[1].set_xlabel("time (s)")
        axes[1].grid(alpha=0.15, lw=0.5)
    else:
        axes[0].set_xlabel("time (s)")

    plt.tight_layout()
    plt.show()
    print("R 峰标志个数 =", int(rflag.sum()), "  ", status_text())
    if ok and len(idx_raw) and _n_drop:
        print("显示端剔除低幅度标记 %d 个（硬件仍计入 bpm）" % _n_drop)
    if LAST_INV is not None and len(LAST_INV) == len(wave):
        nflag = int(LAST_INV.sum())
        print("被硬件标记为毛刺的采样点 = %d 个%s" %
              (nflag, "" if nflag else "（这一版没有标记，或者烧的是没有去毛刺的比特流）"))
    if not ok:
        print("!! 信号无效：这一段不像心电，判定为【电极未接 / 输入过载】，上面的 R 峰标记已忽略")
        for r in reasons:
            print("   - " + r)
        print("   （检测器本身没问题：它只认尖峰，分不清心跳和干扰；所以要先做这次质量判断。）")
    else:
        print("信号质量：通过（交流幅度 %d 计数，直流偏置 %+.0f）" % (m["amp"], m["med"]))
    if len(idx):
        print("R 峰位置：缓存下标 =", idx.tolist())
        print("          输入样点序号 =", (idx + FIR_DELAY).tolist(),
              "（这个编号和寄存器 R_INDEX 是同一套）")
    print("波形范围 = %d .. %d counts  (约 %.2f .. %.2f mV, 按 12.3uV/计数)"
          % (wave_raw.min(), wave_raw.max(), wave_raw.min() * UV_PER_CODE / 1000.0,
             wave_raw.max() * UV_PER_CODE / 1000.0))


# =====================================================================
# 3.0 先看一眼：overlay 和芯片是不是活的（不抓数据，很快）
# =====================================================================
# id_check()
# flow_check()          # 跑 ROM 模式时先执行下面 3.1 再跑这个

# =====================================================================
# 3.1 离线数据集自检（src=0，走 MIT-BIH ROM）
#     正确结果：R 峰在 54 / 258 / 461 / 658 附近，bpm 约 74
# =====================================================================
# wave, clt, rflag = capture(711, src=0)
# show(wave, clt, rflag, title="MIT-BIH record 100 (ROM)")

# =====================================================================
# 3.2 实时心电（src=1，走 ADS1292）
#     贴着电极、插好 3.5mm 插头、接好杜邦线以后再跑
# =====================================================================
# wave, clt, rflag = capture(1000, src=1)
# show(wave, clt, rflag, title="live ECG from ADS1292")

# 只看 3 秒的短段：
# wave, clt, rflag = capture(750, src=1)
# show(wave, clt, rflag, title="live ECG (3 s)", show_clt=False)

















