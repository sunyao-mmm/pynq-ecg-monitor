# -*- coding: utf-8 -*-
"""
诊断.py —— PYNQ-Z2 心电项目 · 一次性体检脚本（读通道1版 / 读通道2版都能用）

怎么用：
  把本文件和 ecg_bd_wrapper.bit / ecg_bd_wrapper.hwh 放在同一个文件夹
  （放在板端当前演示目录，例如 /home/xilinx/jupyter_notebooks/shishixianshi/），
  在 Jupyter 里新建一个 cell：

      %run 诊断.py

它会依次做四件事，并把结论直接打印出来：
  1) 确认板子上跑的比特流对不对（读 0x2C ID 寄存器 = 0x0EC60001）
  2) 问芯片"你在不在"（读 0x08 自检字：芯片ID / 读到几帧 / 帧状态）
  3) 跑一遍离线 ROM（record 100），确认 FPGA 主线没被新比特流弄坏
  4) 实时抓 4 秒，算出"这段像不像真人心电"，并统计出现次数最多的几个值
     —— 这一张表就能看出是不是读到了一个"空通道"

同时会把原始数据存成 诊断_结果.csv、把图存成 诊断_波形.png，方便发给我看。

======================================================================
两个开关（一般不用动）
======================================================================
FORCE_RELOAD = False
    改成 True 会强制把 .bit 重新下载一遍 —— 这会让 ADS1292 的初始化流程
    （RESET → 配置寄存器 → 读ID → START）重新跑一次。要用逻辑分析仪抓
    初始化那一段波形时，先让分析仪开始录，再把这个开关打开跑本脚本。
SKIP_ROM_CHECK = False
    改成 True 就跳过第 3 步（离线 ROM 自检），省时间。
"""

import os
import time
import csv

import numpy as np
import matplotlib.pyplot as plt
from pynq import Overlay, MMIO

# ----------------------------------------------------------------------
# 开关
# ----------------------------------------------------------------------
# ↓↓↓↓↓↓↓↓ 就把下面这一行的 False 改成 True（T 大写），别的字一个都别动 ↓↓↓↓↓↓↓↓
FORCE_RELOAD = False
# ↑↑↑↑↑↑↑↑ 改成 True 之后，跑脚本时会看到 ">> 已强制重新下载比特流" ↑↑↑↑↑↑↑↑
SKIP_ROM_CHECK = False

# ----------------------------------------------------------------------
# 常量
# ----------------------------------------------------------------------
BITFILE = "ecg_bd_wrapper.bit"
FS_HZ = 250.0            # 采样率 250 Hz
FIR_DELAY = 32           # FIR 群延迟（样点）

CTRL      = 0x00         # bit0 run, bit1 soft_rst, bit2 src_sel
STATUS    = 0x04
CLT_NOW   = 0x08
R_INDEX   = 0x0C
BPM       = 0x14
BEAT      = 0x1C
CAP_LEN   = 0x24
ID        = 0x2C
CAP_ADDR  = 0x30
CAP_DATA  = 0x34

# 满量程参考：我们取的是 24 位里的高 16 位，所以满量程 = ±32768 计数
FULL_SCALE = 32768

# 上一次 capture() 到底抓成功了没有。
#   True  = cap_done 正常到达，缓冲区里是本轮的新数据
#   False = 等 cap_done 超时——硬件没有"清缓存"的操作（soft_rst 只清地址、不清内容），
#           所以这时缓冲区里很可能还是**上一次**抓的旧内容。
#           这种情况下面所有波形/信号质量的判断都必须作废。
LAST_CAP_OK = True


def hx(v):
    return "0x%08X" % (int(v) & 0xFFFFFFFF)


def line(c="-", n=74):
    print(c * n)


def title(s):
    print()
    line("=")
    print(s)
    line("=")


# ----------------------------------------------------------------------
# 1) 打开 overlay
# ----------------------------------------------------------------------
title("1) 打开 overlay，确认比特流是我们要的那一份")

try:
    st = os.stat(BITFILE)
    print("比特流文件 : %s" % os.path.abspath(BITFILE))
    print("           大小 %.2f MB    文件修改时间 %s"
          % (st.st_size / 1048576.0, time.ctime(st.st_mtime)))
    print("           （和你在 Vivado 里生成/复制的时间对一下）")
except OSError as e:
    raise SystemExit("!! 这个文件夹里找不到 %s ：%s" % (BITFILE, e))

ol = Overlay(BITFILE)

if FORCE_RELOAD:
    try:
        ol.download()
        print(">> 已强制重新下载比特流（ADS1292 初始化会重跑一遍）")
        time.sleep(1.5)
    except Exception as e:
        print(">> 强制重新下载没成功（%s: %s）" % (type(e).__name__, e))
        print(">> 不影响后面读数据；如果想达到同样效果，给板子断电重上再跑一次本脚本")

mm = MMIO(ol.ip_dict["ecg_axil_0"]["phys_addr"], 0x1000)


def rd(off):
    return mm.read(off)


def wr(off, val):
    mm.write(off, int(val))


rid = rd(ID)
if rid == 0x0EC60001:
    print("ID 寄存器 = %s   OK（AXI 通了，工程是对的）" % hx(rid))
else:
    print("ID 寄存器 = %s   !! 不对（应该是 0x0EC60001）" % hx(rid))
    print("   典型原因：.hwh 没改名成 ecg_bd_wrapper.hwh，或者 .bit/.hwh 不是同一版")

# 停下来，让 0x08 显示自检字
wr(CTRL, 0x0000)
time.sleep(0.2)


# ----------------------------------------------------------------------
# 2) 问芯片"你在不在"
# ----------------------------------------------------------------------
title("2) 问 ADS1292：你在不在？（0x08 自检字）")

print("说明：这套比特流在配置完芯片之后，会把芯片的 ID 寄存器读回来，")
print("      连同'读到几帧''最后一帧的状态字节'一起放进 0x08 寄存器。")
print("      0x08 = 0xEC_ss_cc_ii   (ss=状态字节 cc=帧数 ii=芯片ID)")
print()

# 芯片初始化完会往这里写 3 次（大约在下载比特流之后的 1 秒 / 2 秒 / 3 秒），
# 每一次都会覆盖上一次。最早那次是刚发完 START、还没收到任何数据时写的，
# 所以"帧数"必然是 0 —— 不能一读到非零就停，要把 3 次都看全，以最后一次为准。
seen = []
t0 = time.time()
while time.time() - t0 < 9.0:
    v = rd(CLT_NOW)
    if v != 0 and (not seen or seen[-1] != v):
        seen.append(v)
    time.sleep(0.2)
v = seen[-1] if seen else 0

if len(seen) > 1:
    print("按时间先后一共看到 %d 次自检字：" % len(seen))
    for k, sv in enumerate(seen):
        print("   第 %d 次 = %s   (芯片ID=0x%02X, 帧数=%d, 状态=0x%02X)"
              % (k + 1, hx(sv), sv & 0xFF, (sv >> 8) & 0xFF, (sv >> 16) & 0xFF))
    print("   （以【最后一次】为准：前几次是在还没收到数据的时候写的，帧数当然是 0）")
    print()

diag_tag = (v >> 24) & 0xFF
diag_status = (v >> 16) & 0xFF
diag_frames = (v >> 8) & 0xFF
diag_chip = v & 0xFF

print("0x08 = %s" % hx(v))

if v == 0:
    print("  -> 完全没有自检数据（一直是 0）")
    print("     (a) 板子上这份 .bit 不是带自检的那一版；或")
    print("     (b) 初始化压根没跑完（芯片/接线/RESET 有问题）")
elif diag_tag != 0xEC:
    print("  -> 不是自检字（0x%02X 开头）。多半是已经 run=1，0x08 在显示实时 CLT。" % diag_tag)
    print("     刚才已经写了 CTRL=0，如果还是这样，说明 0x08 被别的东西占着。")
else:
    print("     芯片 ID      = 0x%02X" % diag_chip)
    print("     已读到帧数   = %d" % diag_frames)
    print("     帧状态字节   = 0x%02X" % diag_status)

chip_alive = None      # True / False / None(未知)
if diag_tag == 0xEC:
    if diag_chip == 0x53:
        print("  结论：芯片是普通 ADS1292，而且它【回话了】—— SPI 五根线是通的 ✅")
        chip_alive = True
    elif diag_chip == 0x73:
        print("  结论：芯片是带呼吸的 ADS1292R（也回话了）✅")
        chip_alive = True
    elif diag_chip == 0x5A:
        print("  结论：读到 0x5A = 自己发出去的字节被自己收到了")
        print("        （DOUT 和 DIN 还短接着，环回测试没拆——这不算芯片的回答）")
        chip_alive = False
    elif diag_chip in (0x00, 0xFF):
        print("  结论：芯片【没有回话】—— ID 读回来是 0x%02X" % diag_chip)
        chip_alive = False
    else:
        print("  结论：ID 读回来是 0x%02X，不是 0x53/0x73，先当成'没回话'处理" % diag_chip)
        chip_alive = False

if diag_tag == 0xEC:
    if diag_frames == 0:
        print("  帧数 = 0  ——  FPGA 一直没看到 DRDY 的下降沿（芯片没在出数据）")
    else:
        print("  帧数 = %d  ——  DRDY 在动、芯片在出数据 ✅" % diag_frames)


# ----------------------------------------------------------------------
# 采集函数
# ----------------------------------------------------------------------
def status_text():
    s = rd(STATUS)
    return ("cap_done=%d  beat_count=%d  bpm=%d  rr=%d  rr_bad=%d"
            % ((s >> 1) & 1, rd(BEAT) & 0xFFFF, rd(BPM) & 0xFFFF,
               rd(0x18) & 0xFFFF, rd(0x20) & 0xFFFF))


def clt_flow(seconds=1.0):
    a = rd(CLT_NOW)
    time.sleep(seconds)
    b = rd(CLT_NOW)
    return a, b, (a != b)


def capture(n_samples=1000, src=0, timeout=None):
    global LAST_CAP_OK
    """抓一段。src=0 走 MIT-BIH ROM，src=1 走 ADS1292。
    返回 (wave, clt, rflag, words)：
      wave  = 滤波后的波形(int16)  clt = 相关曲线(CLT)
      rflag = R 峰标志 0/1        words = 从缓存里读回来的原始 32 位字"""
    n = int(max(1, min(n_samples, 2048)))
    src_bit = 0x04 if src else 0x00

    wr(CAP_LEN, n)
    wr(CTRL, 0x02 | src_bit)          # soft_rst，清缓存清检测器
    time.sleep(0.05)
    wr(CTRL, 0x01 | src_bit)          # run = 1

    if timeout is None:
        timeout = n / FS_HZ + 2.0
    t0 = time.time()
    LAST_CAP_OK = False
    while (rd(STATUS) & 0x02) == 0:
        if time.time() - t0 > timeout:
            print("!! 等 cap_done 超时：数据没进来")
            print("!! 缓存没有清零操作，此刻缓冲区里很可能还是【上一次】抓的旧内容；")
            print("!! 下面的波形和'信号质量'判断一律作废。")
            break
        time.sleep(0.02)
    if (rd(STATUS) & 0x02) != 0:
        LAST_CAP_OK = True
    dt = time.time() - t0
    # 这一行很有用：它等于"实际采样率"。真的是 250 Hz 的话，1000 个点大约 4 秒。
    # 如果远快于这个数，说明进样点的节拍不对（比如 DRDY 在乱跳）。
    if dt > 0.05:
        print("   抓这 %d 个点用了 %.2f 秒  →  实际进样率约 %.0f Hz （正常应接近 250）"
              % (n, dt, n / dt))
    time.sleep(0.05)

    words = np.zeros(2 * n + 1, dtype=np.uint32)
    for k in range(2 * n + 1):
        wr(CAP_ADDR, k)
        words[k] = rd(CAP_DATA)

    # 缓存格式：地址 0 永远是空的；奇数地址 = 波形字（bit16 = R 标志）；
    #           偶数地址 = CLT 曲线
    wsrc = words[1::2].astype(np.int64)
    flags = (wsrc >> 16) & 1
    clt = words[2::2].astype(np.int64)[:n]
    raw = (wsrc & 0xFFFF).astype(np.int64)
    wave = np.where(raw >= 0x8000, raw - 0x10000, raw).astype(np.int16)[:n]
    return wave, clt, flags.astype(np.int64)[:n], words


def refine_peaks(wave, rflag, back=25):
    pk = []
    for p in np.where(rflag == 1)[0]:
        lo = max(0, p - back)
        seg = np.abs(wave[lo:p + 1].astype(np.int64))
        pk.append(lo + int(np.argmax(seg)))
    return np.array(sorted(pk), dtype=int)


def value_census(wave):
    """统计每个值出现多少次 —— 读空通道时这里会露馅。"""
    d = {}
    for x in wave.tolist():
        d[x] = d.get(x, 0) + 1
    top = sorted(d.items(), key=lambda kv: -kv[1])[:5]
    return len(d), top


def quality(wave):
    """返回 (是否像真人心电, 原因列表, 指标字典)"""
    w = wave.astype(np.int64)
    amp = int(np.abs(w).max()) if len(w) else 0
    med = float(np.median(w)) if len(w) else 0.0
    hi, lo = int(w.max()), int(w.min())
    half = max(1.0, (hi - lo) / 2.0)
    frac_ext = float(np.mean(np.abs(w - med) > 0.6 * half)) if len(w) else 0.0
    bad = []
    if amp > 0.15 * FULL_SCALE:
        bad.append("幅度过大（峰值 %d 计数，超过满量程的 15%%）" % amp)
    if amp > 0 and abs(med) > 0.25 * amp:
        bad.append("基线严重偏移（中位数 %+.0f，是峰值的 %.0f%%）" % (med, abs(med) / amp * 100))
    if frac_ext > 0.50:
        bad.append("长时间贴在上下限（%.0f%% 的时间在极值附近）" % (frac_ext * 100))
    return (len(bad) == 0), bad, dict(amp=amp, med=med, frac_ext=frac_ext)


def dump_words(words, count=24):
    print("   原始缓存前 %d 个字（每 2 个字 = 1 个采样点）：" % count)
    for i in range(0, min(count, len(words)), 8):
        print("     addr %4d : %s" % (i, " ".join(hx(w) for w in words[i:i + 8])))


# ----------------------------------------------------------------------
# 3) 离线 ROM 自检（确认 FPGA 主线没被弄坏）
# ----------------------------------------------------------------------
if not SKIP_ROM_CHECK:
    title("3) 离线自检：跑板子上那份 ROM（你板子里是 record 208）")
    print("    record 208 的预期：R 峰约在 132 / 451 / 617（输入样点序号）")
    print("    record 100 的预期：R 峰约在  54 / 258 / 461 / 658")
    print("    对不上哪一份不重要，只要能稳定检出 3~4 个峰、间隔均匀就行。")
    print()
    wave, clt, rflag, words = capture(711, src=0)
    pk = refine_peaks(wave, rflag)
    print("波形范围 = %d .. %d 计数    R 峰标志个数 = %d"
          % (wave.min(), wave.max(), int(rflag.sum())))
    print("R 峰位置（缓存下标） =", pk.tolist())
    print("输入样点序号         =", (pk + FIR_DELAY).tolist())
    print(status_text())
    ok_rom = LAST_CAP_OK and (len(pk) >= 3)
    if not LAST_CAP_OK:
        print("判定：!! 本次抓取根本没完成（cap_done 没来）——上面的波形是缓存里的旧内容，不能当结果")
    else:
        print("判定：%s" % ("主线正常 ✅（R 峰位置和预期一致就说明新比特流没弄坏主线）" if ok_rom
                           else "!! 主线异常：ROM 都没跑出 R 峰，先别管采集，把这行结果发我"))
else:
    print()
    print("（跳过第 3 步 ROM 自检）")


# ----------------------------------------------------------------------
# 4) 实时采集
# ----------------------------------------------------------------------
title("4) 实时采集（src=1，走 ADS1292），抓 4 秒")

a, b, moving = clt_flow(1.0)
print("CLT_NOW : %s -> %s   (%s)" % (hx(a), hx(b), "数据在动" if moving else "没动！采样没进来"))
print("STATUS  :", status_text())
print()

wave, clt, rflag, words = capture(1000, src=1)
print("波形范围 = %d .. %d 计数" % (wave.min(), wave.max()))
n_uniq, top = value_census(wave)
print("不重复的值的个数 = %d  (1000 个点里只有 %d 种取值)" % (n_uniq, n_uniq))
print("出现次数最多的 5 个值（值 : 次数）：")
for val, cnt in top:
    print("    %+8d : %4d 次" % (val, cnt))
print(status_text())
dump_words(words, 24)

ok, bad, m = quality(wave)
if not LAST_CAP_OK:
    ok = False
    bad = ["本次抓取未完成（cap_done 没来），缓冲区里很可能是上一次的旧内容"]
print()
if n_uniq <= 12:
    print("!! 这一段几乎是'死'的：1000 个点只有 %d 种取值 —— 说明数据通路没在真正更新" % n_uniq)
if ok:
    print("信号质量：像真人心电 ✅（幅度 %d 计数，基线 %+.0f）" % (m["amp"], m["med"]))
else:
    print("信号质量：不像真人心电 ✗")
    for r in bad:
        print("   - " + r)

pk = refine_peaks(wave, rflag)
print("R 峰标志个数 = %d" % int(rflag.sum()))
if len(pk):
    print("R 峰位置（缓存下标） =", pk.tolist()[:20])

# ---- 存文件 ----
csv_name = "诊断_结果.csv"
with open(csv_name, "w", newline="") as f:
    wtr = csv.writer(f)
    wtr.writerow(["index", "wave", "clt", "rflag"])
    for i in range(len(wave)):
        wtr.writerow([i, int(wave[i]), int(clt[i]) if i < len(clt) else "",
                      int(rflag[i])])
print()
print("原始数据已存：%s" % os.path.abspath(csv_name))

fig, ax = plt.subplots(2, 1, figsize=(11, 6.4), sharex=True)
t = np.arange(len(wave)) / FS_HZ
ax[0].plot(t, wave, lw=0.9)
ax[0].set_ylabel("ADC counts")
ax[0].set_title("live from ADS1292  %d samples = %.1f s   [%s]"
                % (len(wave), len(wave) / FS_HZ,
                   "OK" if ok else ("STALE / capture never finished" if not LAST_CAP_OK else "INVALID")))
ax[0].grid(alpha=0.3)
ax[1].plot(t, clt, lw=0.9, color="green")
ax[1].set_ylabel("CLT")
ax[1].set_xlabel("time (s)")
ax[1].grid(alpha=0.3)
plt.tight_layout()
plt.savefig("诊断_波形.png", dpi=110)
print("波形图已存：%s" % os.path.abspath("诊断_波形.png"))
plt.show()


# ----------------------------------------------------------------------
# 总结
# ----------------------------------------------------------------------
title("总结：下一步做什么")

if chip_alive is False:
    print("芯片【没有回话】(ID=0x%02X, 帧数=%d)。" % (diag_chip, diag_frames))
    print()
    print("=> 这种情况下，换读通道（通道1/通道2）【不会】有区别：")
    print("   芯片连 ID 都不回答，说明命令根本没进芯片，或者它没把数据送回来。")
    print("   先别急着重新生成比特流，优先查这五根线里到底哪一根没通：")
    print("     SCLK / CS / DIN  —— FPGA 发给芯片的（芯片收不到就不动）")
    print("     DOUT            —— 芯片发给 FPGA 的（这根断了 = 读到的永远是 1）")
    print("     DRDY            —— 芯片告诉 FPGA '新数据好了'")
    print("   用逻辑分析仪：CH1~CH4 夹 SCLK/CS/DIN/DOUT，GND 夹板子的 GND，")
    print("   把本脚本顶上的 FORCE_RELOAD 改成 True 再跑一次，")
    print("   初始化那段（约 1 秒后出现的密集脉冲群）就能抓到。")
elif chip_alive is True:
    if diag_frames == 0:
        print("芯片回话了(ID=0x%02X)，但帧数=0 —— 命令通了，DRDY 没通。" % diag_chip)
        print("=> 重点查 DRDY 这一根线（以及它接的 PYNQ 引脚）。")
    else:
        print("芯片回话了(ID=0x%02X)，也在出数据（帧数=%d）✅" % (diag_chip, diag_frames))
        print("=> 那问题就在'读的是不是接了电极的那个通道'，或者模拟前端本身。")
        print("   现在这份是【读通道 2】还是【读通道 1】的比特流，你自己心里有数；")
        print("   把上面那张'出现次数最多的 5 个值'的表抄下来，")
        print("   换另一份 ads1292_spi.v 重新生成比特流以后再跑一次本脚本，")
        print("   两张表一比就知道哪个通道才是有电极的那个。")
else:
    print("自检字没解出来（见第 2 节），先把那一节的输出发我。")

print()
print("把这一整屏输出 + 桌面 test 文件夹里的内容发我，我接着给你下一步。")
