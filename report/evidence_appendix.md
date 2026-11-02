# 验证与优化证据补充

本文件补充主报告篇幅未展开的测试矩阵、优化对比和 MIT-BIH 统计口径。主报告中的结论以本文件和对应原始日志为准。

## 1. RTL 与网页验证矩阵

| 用例 | 覆盖模块 | 关键激励或条件 | 判定标准 | 实际结果 | 证据 |
|---|---|---|---|---|---|
| `tb_ecg_axil` | AXI-Lite、寄存器、缓存读回 | AXI 写读、CTRL/STATUS、CAP_LEN、CAP_DATA | 27 项断言全部通过 | PASS | `sim/logs/tb_ecg_axil.log` |
| `tb_ads1292_spi` | ADS1292 SPI 与帧解析 | 命令序列、ID、DRDY、9 字节帧 | 14 项检查通过 | PASS | `sim/logs/tb_ads1292_spi.log` |
| `tb_notch_50hz` | 50 Hz 陷波 | 50 Hz、10 Hz 和阶跃输入 | 50 Hz 被抑制，10 Hz 保持 | PASS | `sim/logs/tb_notch_50hz.log` |
| `tb_ecg_detect` | 陷波、FIR、CLT | ROM 100 黄金峰 | TP=4、FP=0、FN=0 | PASS | `sim/logs/tb_ecg_detect.log` |
| `tb_ecg_core` | ROM、检测、心率、缓存整链 | record 100 全链回放 | 22 项检查通过 | PASS | `sim/logs/tb_ecg_core.log` |
| `tb_heart_rate` | RR 中位数与异常 RR | 正常和超范围 RR | 输出和 `rr_bad` 符合预期 | PASS | `sim/logs/tb_heart_rate.log` |
| `tb_ecg_continuous` | 普通/连续采集模式 | 达到 CAP_LEN、连续写入和指针遍历 | 普通模式停止，连续模式遍历全部位置 | PASS | `sim/logs/tb_ecg_continuous.log` |
| `tb_ring_memory` | 连续缓存地址映射 | 连续覆盖至少 4 次回绕 | 波形字、CLT 字和写地址始终对齐 | PASS | `sim/logs/tb_ring_memory.log` |
| `tb_rom_long` | 长时 ROM 回归 | record 208 连续 105 圈 | 每圈 4 拍，`rr_bad=0` | PASS | `sim/logs/tb_rom_long.log` |
| `test_web_logic` | PS 数据转换、峰值、节律与 PVC 复核 | 合成波形和边界条件 | 12 项检查通过 | PASS | `tools/test_web_logic.py` |

## 2. 优化前后对比

| 阶段 | PL 时钟 | LUT | DSP | WNS | 失败端点 | 主要变化 |
|---|---:|---:|---:|---:|---:|---|
| 初始高时钟实现 | 100 MHz | 未单独保留 | 未单独保留 | -25.86 ns | 506 | 串行 MAC、argmax 和陷波路径过长 |
| 低时钟静态采集版 | 20 MHz | 4,053（7.62%） | 6（2.73%） | +7.139 ns | 0 | 降低时钟，保留串行结构 |
| 最终连续显示版 | 20 MHz | 4,417（8.30%） | 6（2.73%） | +0.036 ns | 0 | 增加连续缓存、写指针和网页显示支持 |

最终版其余资源：FF 3,461（3.25%），BRAM 4.5（3.21%）。各行对应不同开发阶段，不能视为同一比特流内的参数切换。

## 3. 检测时延拆分

| 项目 | 数值或条件 | 说明 |
|---|---|---|
| FIR 群延迟 | 约 128 ms | 65 抽头线性相位 FIR，群延迟 32 个采样点 |
| 网页轮询周期 | 80 ms | 前端定时请求最新状态 |
| 显示与分析窗口 | 2000 点 | 约 8 秒的历史数据窗口 |
| 端到端显示时延 | 未单独测量 | 不能将 FIR 群延迟直接等同于 CPU 调度或网络时延 |

## 4. MIT-BIH 统计口径

使用官方 MIT-BIH Arrhythmia Database 1.0.0 检查 23 条记录，其中 14 条通过时间轴可信检查。可信记录汇总如下：

- 标注心搏：30,447
- TP / FN / FP：29,902 / 545 / 477
- Se：98.21%
- PPV：98.43%

| 未计入总体的记录 | 自动对齐率 | 处理口径 |
|---|---:|---|
| 114 | 38.3% | 首通道为 V5，与当前固定导联验证流程不匹配 |
| 119 | 88.0% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |
| 121 | 21.5% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |
| 200 | 46.4% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |
| 220 | 87.8% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |
| 223 | 70.0% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |
| 230 | 31.3% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |
| 233 | 44.0% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |
| 234 | 70.5% | ATR 特殊标注解析后的时间轴未达到 90% 阈值 |

上述记录未计入总体 Se/PPV，但完整逐记录结果仍保留在 `data/mitbih/verification_results.md`。该汇总不代表 MIT-BIH 全库性能。
