---
name: fpga-agent-workflow
description: Guide LLM-assisted FPGA debugging with symptom-first evidence, minimal experiments, version checks, and reusable case records for hardware, RTL, Vivado, and PYNQ work.
---

# FPGA Agent Workflow

## 适用场景

用于大模型参与 RTL、Vivado、PYNQ、SPI、时序和板级调试的过程。目标不是让模型猜答案，而是让每次修改都有现象、假设、最小验证、结果和回退边界。

## 核心循环

1. 人提供可观察的物理事实：截图、寄存器值、波形、接线和供电状态。
2. 模型提出一个最可能原因，以及成本最低的验证方法。
3. 一次只改一个变量，先跑仿真或只读检查，再决定是否改 RTL 或重新生成比特流。
4. 记录“现象—假设—验证—结果—是否推翻”。
5. 成功后把检查固化成脚本或检查项，失败则保留案例和回退版本。

## 使用方法

先用 [references/prompts.md](references/prompts.md) 选择提问模板；用 [references/case_template.md](references/case_template.md) 记录问题；用 [references/pitfalls.md](references/pitfalls.md) 快速定位常见错误。

## 已验证效果

本工作流来自真实项目问题：

| 观察 | 使用前 | 验证后的结果 |
|---|---|---|
| 100 MHz 实现时序失败 | 506 个失败端点，WNS -25.86 ns | 调整为符合真实带宽的 20 MHz 串行结构并完成物理优化后，失败端点 0，最终 WNS +0.036 ns |
| Block Design 覆盖 RTL 参数 | 采样率约 50 Hz | 核对实例参数后恢复约 229～243 Hz |
| ROM 正常但实时输入为常数 | 帧数增长、波形不动 | 检查物理导联和电极后恢复实时波形 |
| 采集超时后读取旧缓存 | 波形和当前数据源不一致 | 检查 cap_done 和缓存批次，避免把旧数据当作实时数据 |
| T 波、毛刺、阈值或版本误导 R 峰 | 标记偏移或批量指标异常 | 用黄金峰值、信号质量、版本和参数记录逐项排除 |

## 失效条件

- 没有物理事实时，模型只能提出假设，不能替代示波器、逻辑分析仪或万用表。
- 涉及可能损伤硬件的接线、供电、短路或电压改动时，必须先由人确认并停止自动执行。
- 对安全关键或医疗诊断结论，不能把模型的波形判断直接当作最终结论。
- 本工作流不保证算法有效，只保证排查过程可追踪、可回归。
