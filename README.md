# PYNQ-Z2 心电监测系统

本项目基于 PYNQ-Z2（Zynq-7000）实现实时心电采集与心律分析。PL 端完成 ADS1292 SPI 读取、50 Hz 陷波、65 抽头 5～40 Hz FIR 带通滤波、CLT R 峰检测、心率与 RR 间期计算，以及连续环形缓存。PS 端通过 AXI-Lite 读取硬件结果，并利用网页完成 ECG/CLT 滚动显示、信号质量判断、心率稳定计算和正常/室早候选复核。系统支持 MIT-BIH 记录离线回放和 ADS1292 人体心电采集。

## 主要结果

| 指标 | 结果 |
|---|---|
| PL 时钟 | 20 MHz |
| 时序 | WNS +0.036 ns，WHS +0.039 ns，失败端点 0 |
| 资源 | LUT 4,417（8.30%）、FF 3,461（3.25%）、BRAM 4.5（3.21%）、DSP 6（2.73%） |
| MIT-BIH | 23 条记录中 14 条通过时间轴可信检查，Se 98.21%、PPV 98.43% |
| 实时网页 | 2000 点滚动显示与分析，固定局部峰峰值门槛，BPM/RR 使用最近 4 个有效 RR 的中位数 |

## 目录

```text
src/rtl/              RTL 源码与 XDC 约束
sim/testbench/        ModelSim/Vivado testbench
build/                Vivado 重建脚本、工程压缩包、timing/util 报告
board/                最终比特流、HWH、网页主界面和板端启动脚本
data/rom/             15 个 MIT-BIH COE 与生成脚本
data/mitbih/          MIT-BIH 批量验证脚本和结果
skill/                可复用 PYNQ、Vivado、黄金比对和 AI 工作流技能包
report/               设计报告、性能数据与 AI 协作记录
tools/                普通采集诊断、现场排障和 PVC 辅助脚本
```

## 从零复现与上板运行

### 快速路径

若仅需进行板端演示，可直接使用 `board/` 中的最终 `.bit`、`.hwh` 和网页文件。若需复现 Vivado 工程，请将 `build/pulsecore_project.zip` 解压至可写目录并打开 `project_1/project_1.xpr`；如需重新生成比特流，可按第 1 节步骤执行。从空工程搭建时，请继续参考第 5 节的 Block Design 配置。

---

## 1. 从零搭建步骤

1. **新建工程**：新建 RTL 工程。在 Vivado 新建向导的 Boards 选项卡中选择 PYNQ-Z2（如果没有，需先安装板卡文件）。选择板卡后，器件锁定为 `xc7z020clg400-1`，并预置 DDR 和 FIXED_IO。
2. **添加源码**：将第 3 节列出的 8 个 RTL Verilog 文件加入 Design Sources，并将 `ads1292_pins.xdc` 加入 Constraints。完成 Block Design 和 HDL Wrapper 后，综合顶层应为 `ecg_bd_wrapper`，不是 `ecg_core`。
3. **创建 Block Design**：按 5.1 添加 9 个模块，按 5.3 连线，按 5.2 引出 5 个外部端口。
4. **核对参数**：`ecg_core_0` 的 `CLK_PER_SAMPLE = 80000`；`ads1292_spi_0` 的三个参数见第 4 节。
5. **检查时钟频率**：各模块 `clk` 引脚与 `FCLK_CLK0` 的 `FREQ_HZ` 均应为 `20000000`，否则 HDL Generation 会报 `[BD 41-238]`。保存 Block Design 后，右键 `ecg_bd.bd`，选择 Create HDL Wrapper，并保持顶层为 `ecg_bd_wrapper`。
6. **生成输出与比特流**：Generate Output Products → Generate Bitstream，确认 WNS ≥ 0、失败端点 = 0。
7. **导出硬件**：执行 Export Hardware 并勾选 Include bitstream。确认 `ecg_bd_wrapper.bit` 与 `ecg_bd_wrapper.hwh` 同名且位于同一目录。
8. **部署到板端**：将 `board/` 中的 `.bit`、`.hwh`、`ecg_web.py`、`index.html` 和 `run_web.sh` 放入开发板上的同一目录。
9. **启动网页**：打开板端终端并进入部署目录，执行：

```bash
pkill -f '[e]cg_web.py' || true
sh run_web.sh 1   # 实时 ADS1292
# 或
sh run_web.sh 0   # MIT-BIH ROM
```

浏览器访问脚本输出的 `http://<板卡IP>:8899/`。若 `.bit/.hwh` 使用自定义名称，需确保两者主文件名一致，并通过 `python3 ecg_web.py --bit <文件名>.bit --source 1` 启动。网页是唯一面向用户的产品界面；`tools/pynq_ecg.py` 仅用于普通采集诊断。
10. **核对**：按第 7 节的判据逐条检查。

如果使用仓库内工程，可在解压后执行：

```bash
vivado -mode batch -source build/rebuild.tcl
```

---

## 2. 环境清单

| 项目 | 要求 | 说明 |
|---|---|---|
| Vivado | 2024.2 | 本项目最终工程、综合、实现和时序报告均在该版本验证 |
| 开发板 | PYNQ-Z2（`xc7z020clg400-1`） | 板上运行 PYNQ 镜像（Ubuntu 20.04 + Python 3.10） |
| 模拟前端 | ADS1292 心电模块 + 3.5 mm 三导联线 | 另需一次性心电电极片 |
| 电源 | 5 V，**优先使用充电宝** | 接笔记本 USB 时工频干扰明显增大 |
| 仿真（可选） | ModelSim 10.4 | 只用于跑 `tb_*.v` |
| 电脑（可选） | Python 3 + numpy | 只用于跑 MIT-BIH 批量验证 |

---

## 3. 文件清单

| 文件 | 作用 |
|---|---|
| `notch_50hz.v` | 50 Hz 工频陷波（二阶 IIR，按实测进样率 243.65 Hz 设计） |
| `fir_bandpass.v` | 65 抽头 5–40 Hz 带通，串行 MAC（全设计只用 1 个乘法器） |
| `clt_qrs.v` | CLT 曲线长度 + 自适应阈值的 R 峰检测状态机 |
| `ecg_detect_top.v` | 陷波 → FIR → CLT 三级串联 |
| `heart_rate.v` | RR 间期与 bpm（最近 4 拍 RR 中位数） |
| `ads1292_spi.v` | ADS1292 的 SPI 配置与 9 字节数据帧读取 |
| `ecg_core.v` | 数据源选择、采样节拍、采集缓存写入、状态汇总 |
| `ecg_axil.v` | AXI4-Lite 寄存器窗口（PS 访问 PL） |
| `board/ecg_web.py`、`board/index.html` | 网页主界面、连续环形缓存、ECG/CLT 滚动显示和结果分析 |
| `board/run_web.sh` | 板端网页启动入口 |
| `src/rtl/ads1292_pins.xdc` | 引脚约束（AR7–AR11） |
| `data/rom/ecg_rom_*.coe` | 15 个 MIT-BIH 记录 ROM，均为 1024×16 |
| `data/rom/README.md` | ROM 清单、窗口起点和重新生成命令 |
| `data/rom/make_coe.py` | 从 MIT-BIH 原始数据库重新生成任意记录 ROM |
| `data/mitbih/validate_mitdb.py` | MIT-BIH 批量验证脚本 |
| `data/mitbih/verification_results.md` | 14 条可信记录的 Se/PPV 汇总 |
| `skill/README.md` | 竞赛技能包总说明；包含通用 PYNQ 自检、Vivado 报告审计、黄金比对和调试工作流 |
| `tools/pynq_ecg.py` | 普通采集诊断脚本，不是主演示界面 |
| `tools/pvc_check.py` | 基于 QRS 宽度与 RR 关系的室早辅助检查脚本 |
| `tools/diagnose.py` | 现场诊断脚本，检查帧数、自检字和进样率 |
| `tools/test_web_logic.py` | 网页数据处理逻辑的离线测试 |
| `sim/testbench/tb_*.v` | 9 个 testbench（基础 6 项，加连续缓存、RAM 回绕和长 ROM 回归） |
| `build/pulsecore_project.zip` | 已验证的完整 Vivado 工程归档 |
| `build/rebuild.tcl` | 从打开工程到重新生成 bitstream 的自动化脚本 |

---

## 4. 关键参数

| 参数 | 值 | 在哪里设置 |
|---|---|---|
| 器件 | `xc7z020clg400-1` | 新建工程时选择 |
| PL 时钟 FCLK_CLK0 | **20 MHz** | ZYNQ7 Processing System → Clock Configuration |
| `CLK_PER_SAMPLE` | **80000** | **Block Design 中 `ecg_core_0` 的参数**（覆盖 RTL 默认 400000） |
| `Settle` | 96 | `ecg_core_0` 参数（默认值即可） |
| `Cal First` | 1 | `ecg_core_0` 参数（默认值即可） |
| `REFRACT` | 100（400 ms） | `clt_qrs.v` 参数 + `ecg_core.v` 例化 |
| `THR_NUM` | 13（0.406） | `clt_qrs.v` 局部参数 |
| `LOW_THR_NUM` | 12（0.375） | 长 RR 间隙内的一拍恢复阈值 |
| `RR_MIN` / `RR_MAX` | 108 / 720 采样点 | 30～200 bpm 的有效参考 RR 范围 |
| `LEARN` / `SEARCH` / `REL_PERIOD` | 30 / 22 / 250 | `clt_qrs.v` |
| FIR | 65 抽头，群延迟 32 采样点 | `fir_bandpass.v` |
| CLT 窗长 | 21 采样点 | `clt_qrs.v` |
| 陷波 | fs = 243.65 Hz，f0 = 50 Hz，Q = 8 | `notch_50hz.v` 的 5 个系数 |
| `ads1292_spi_0` | `CLK_HZ` = 20 MHz，`RESET_WAIT` = 20 MHz 周期（1 s），`DIAG_GAP` = 20 MHz 周期（1 s） | Block Design 参数 |
| 采集缓存 | 4096 字 × 32 位；每采样点使用波形字和 CLT 字各一 | `blk_mem_gen_1` |
| 连续模式 | `CAP_LEN[31]=1`，低 12 位为环形窗口长度 | `ecg_core.v` 与 `CAP_LEN` 寄存器 |

**关键注意事项**：Block Design 实例参数优先于 RTL 默认值。仅修改 `.v` 文件而未同步核对 BD 参数时，配置不会生效；本项目曾因此将实际采样率降至约 50 Hz。

---

## 5. Block Design 配置

### 5.1 需要添加的模块（共 9 个）

| 实例名 | 类型 | 关键配置 | 
|---|---|---|
| `processing_system7_0` | ZYNQ7 Processing System 5.5 | 在 Clock Configuration/PL Fabric Clocks 中设置 `FCLK_CLK0 = 20 MHz`；在 PS-PL Configuration 中开启 `M_AXI_GP0`；将 DDR 与 FIXED_IO 引出 |
| `axi_smc` | AXI SmartConnect 1.0 | `NUM_SI = 1` |
| `rst_ps7_0_100M` | Processor System Reset 5.0 | 默认（实例名沿用旧工程，不影响功能） |
| `ecg_axil_0` | RTL 模块引用 `ecg_axil` | 无参数 |
| `ecg_core_0` | RTL 模块引用 `ecg_core` | `CLK_PER_SAMPLE = 80000` |
| `ads1292_spi_0` | RTL 模块引用 `ads1292_spi` | `CLK_HZ = 20000000`、`RESET_WAIT = 20000000`、`DIAG_GAP = 20000000` |
| `blk_mem_gen_0` | Block Memory Generator 8.4 | Mode 选择 Stand Alone；Memory Type 选择 Single-Port ROM；Port A Width 设为 16、Depth 设为 1024；Other Options 中勾选 Load Init File，并选择 `data/rom/ecg_rom_208.coe` |
| `blk_mem_gen_1` | Block Memory Generator 8.4 | Mode 选择 Stand Alone；Memory Type 选择 Simple Dual-Port RAM；Port A Width 设为 32、Depth 设为 4096；不启用字节写 |
| `xlconstant_0` | Constant 1.1 | 输出常值 1，连接至 `ads1292_spi_0/start` |
### 5.2 外部端口（5 个）

| 端口 | 方向 | FPGA 引脚 |
|---|---|---|
| `sclk` | 输出 | V17（AR8） |
| `mosi` | 输出 | R17（AR11） |
| `cs_n` | 输出 | V18（AR9） |
| `miso` | 输入 | U17（AR7） |
| `drdy_n` | 输入 | T16（AR10） |
注意核对 XDC 文件中的端口名称与 Block Design 外部端口名称一致。
模块白色排座从上到下：`5V / DOUT / SCLK / CS / DRDY / DIN / GND`；5V 与 GND 接 Arduino 电源排，不占 FPGA 引脚。

电极正确位置：黄线接左肋（LA），绿线接右肋（RA），红线接右下腹参考位置（RL）。使用新鲜一次性电极片和充电宝供电。禁止把右腿驱动输出直接短接到输入电极。

通电状态下不要重新插拔裸露导线。电极老化或接触不稳时应更换，不应通过提高增益掩盖接触问题。本系统仅用于竞赛作品展示，不作为医疗诊断设备。

### 5.3 连线表（共 30 条，按工程 `ecg_bd.bd` 原样抄录）

| 网络 | 连接 |
|---|---| 
| 时钟 | `processing_system7_0/FCLK_CLK0` → `M_AXI_GP0_ACLK`、`axi_smc/aclk`、`rst_ps7_0_100M/slowest_sync_clk`、`blk_mem_gen_0/clka`、`blk_mem_gen_1/clka`、`blk_mem_gen_1/clkb`、`ecg_axil_0/S_AXI_ACLK`、`ads1292_spi_0/clk`、`ecg_core_0/clk` |
| 复位 | `processing_system7_0/FCLK_RESET0_N` → `rst_ps7_0_100M/ext_reset_in`；`rst_ps7_0_100M/peripheral_aresetn` → `axi_smc/aresetn`、`ecg_axil_0/S_AXI_ARESETN`、`ads1292_spi_0/rst_n`、`ecg_core_0/rst_n` |
| AXI | `processing_system7_0/M_AXI_GP0` ↔ `axi_smc/S00_AXI`；`axi_smc/M00_AXI` ↔ `ecg_axil_0/S_AXI` |
| 控制 | `ecg_axil_0/ctrl_run` → `ecg_core_0/run`；`ctrl_soft_rst` → `soft_rst`；`ctrl_src` → `src_sel`；`cap_len` → `cap_len_in` |
| 状态 | `ecg_core_0` 的 `st_clt_now / st_r_index / st_r_amp / st_bpm / st_rr_samples / st_beat_count / st_rr_bad_cnt / st_cap_done` → `ecg_axil_0` 同名端口 |
| 采集缓存写 | `ecg_core_0/cap_we` → `blk_mem_gen_1/wea`；`cap_addr` → `addra`；`cap_data` → `dina` |
| 采集缓存读 | `ecg_axil_0/cap_rd_addr` → `blk_mem_gen_1/addrb`；`blk_mem_gen_1/doutb` → `ecg_axil_0/cap_rd_data` |
| ROM | `ecg_core_0/rom_addr` → `blk_mem_gen_0/addra`；`blk_mem_gen_0/douta` → `ecg_core_0/rom_data` |
| SPI 数据 | `ads1292_spi_0/sample` → `ecg_core_0/adc_sample`；`sample_valid` → `adc_valid` |
| SPI 引脚 | `ads1292_spi_0/sclk → sclk`、`mosi → mosi`、`cs_n → cs_n`、`miso ← miso`、`drdy_n ← drdy_n` （即右键Make External）|
| 启动 | `xlconstant_0/dout`（常值 1） → `ads1292_spi_0/start` |

> 说明：`ecg_axil` 与 `ecg_core` 之间是**直接连线**，不是 AXI；只有 PS 到 `ecg_axil` 走 AXI。

---

## 6. 常见问题与排查

1. **BD 参数覆盖 RTL**：改了 `ecg_core.v` 却没改 BD 的 `CLK_PER_SAMPLE`，表现为采样率只有 50 Hz。
2. **FREQ_HZ 不一致**：报 `[BD 41-238] Port/Pin property FREQ_HZ does not match`，HDL Generation 失败。
3. **`.hwh` 没改成 `.bit` 的同名**：Overlay 报找不到硬件描述文件。
4. **换比特流后没重启内核**：仍在跑上一版逻辑，表现为"改了代码没效果"。
5. **导联接反**：正确接法为 黄 = LA、绿 = RA、红 = RL（参考）。把红绿当成测量对时，信号幅度会小很多、工频干扰明显变大。
6. **ADS1292 实际进样率约 243.65 Hz**（芯片内部振荡器偏低约 2.5%），因此 PS 端把 bpm 乘以 243.65/250 做校正。
7. **白色排座接触不良**：表现为帧数不涨或波形为常数，按压排座可临时恢复。
8. **电极贴久老化**：接触阻抗上升，基线偏移、噪声变大。
9. **Vivado Tcl 里没有 `ls` / `find`**：用 `exec find` 或 `file stat` 代替。

---

## 7. 复现成功的判据

| 检查项 | 期望值 |
|---|---|
| 寄存器 ID（0x2C） | `0x0EC60001` |
| 默认 ROM 208 的 R 峰 | 132 / 451 / 617 |
| ROM 100 的 R 峰 | 54 / 258 / 461 / 658 |
| ROM 119 的 R 峰 | 约 417 / 639 |
| 默认 ROM 208 的 bpm | 约 90 |
| 实时采集 | 页面持续刷新且波形不是常数；`rr_bad` 不应持续增长 |
| 实时 bpm | 与手数脉搏相差 ≤ 3（PS 端已按实测采样率校正） |
| 实测采样率 | 排除初始化后，用首尾样点间隔计算，约 243.65 Hz |
| 网页 | 默认显示和分析各 2000 点；实时/ROM 可切换；连续运行不回绕错位 |
| 时序 | WNS +0.036 ns，WHS +0.039 ns，失败端点 0 |
| 资源 | LUT 4,417（8.30%）、FF 3,461（3.25%）、BRAM 4.5（3.21%）、DSP 6（2.73%） |
| MIT-BIH 批量验证 | 14 条可信记录，Se 98.21%、PPV 98.43% |

---

## 8. 报告里的关键数据怎么重新生成

| 数据 | 命令 |
|---|---|
| 资源占用 | `open_run impl_1` 后执行 `report_utilization -file util.rpt` |
| 时序 | `open_run impl_1` 后执行 `report_timing_summary -file timing.rpt` |
| 检测性能 | `python validate_mitdb.py --db <MIT-BIH目录> --out 结果.md` |
| 实时波形 | 板上执行 `sh run_web.sh 1`，检查网页 ECG/CLT 是否连续滚动 |
| 普通采集诊断 | 使用 `tools/pynq_ecg.py` 对照固定 2000 点采集 |
| 完整工程重建 | `vivado -mode batch -source build/rebuild.tcl` |

---

## 9. 版本说明

当前版本采用 20 MHz PL 时钟，主要参数为 `REFRACT=100`、`THR_NUM=13`、`LOW_THR_NUM=12`，并包含连续环形缓存回绕修复、网页主界面和正常/室早候选复核。最终比特流为 `ecg_bd_wrapper.bit`，生成时间为 2026-10-30 11:30:11，SHA256 为 `535B1660655551585D79024665AFD06D7D1F3F10D3D5ABA351C6BCEB6AC48790`。
