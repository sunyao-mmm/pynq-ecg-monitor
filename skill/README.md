# FPGA/PYNQ Reusable Skills

本目录是竞赛提交用技能包。所有目录和文件名使用纯英文；每个条目都说明适用场景、使用方法、已验证效果和失效条件。

## 条目总览

| 条目 | 适用场景 | 使用方法 | 已验证效果 | 失效条件 |
|---|---|---|---|---|
| `pynq-overlay-smoke/` | 任意 PYNQ Overlay 或 AXI-Lite IP 的基础自检 | 准备寄存器 JSON 并运行 `scripts/overlay_smoke.py` | 已完成 3 项无板卡模拟后端测试 | 不检查 DMA、中断、缓存一致性；不适用于没有 AXI-Lite 寄存器窗口的 IP |
| `vivado-report-audit/` | Vivado 实现后自动检查时序与资源 | 运行 `scripts/check_reports.py --timing ... --util ...` | 已用本项目最终 `timing.rpt` 和 `util.rpt` 验证通过 | 报告格式随 Vivado 版本可能变化；不替代时序约束审查 |
| `golden-signal-compare/` | 检测结果与黄金参考的区间或峰值比对 | 提供参考和实测整数列表，运行 `scripts/compare_intervals.py` | 已用 record 100 的 4 个 R 峰样例验证，失配时返回非零退出码 | 参考时间轴必须先对齐；不能用它弥补错误的重采样 |
| `fpga-agent-workflow/` | 大模型辅助 FPGA 调试、问题定位和案例沉淀 | 按 `SKILL.md` 选择提示词和案例模板 | 来自本项目时序失败、采样率错误、导联未插、旧缓存和工具链覆盖等真实问题 | 物理接线、示波器和逻辑分析仪事实必须由人提供 |

## 推荐使用顺序

1. 先用 `pynq-overlay-smoke/` 确认 AXI 通路和寄存器窗口。
2. 用 `vivado-report-audit/` 检查实现后的时序与资源。
3. 用 `golden-signal-compare/` 对比检测结果和黄金参考。
4. 遇到复杂问题时用 `fpga-agent-workflow/` 记录现象、验证假设、形成可复用案例。

## 设计来源

- PYNQ 检查流程来自早期 `README_phase2.md` 中“先 Overlay 冒烟测试，再碰 Block Design”的做法。
- 报告检查来自本项目 100 MHz 时序失败、20 MHz 收敛的实际数据。
- 黄金比对来自 record 100/119/208、ROM 回放和 MIT-BIH 批量验证。
- 调试工作流来自本项目多次失败与纠错记录，包括电极未插、BD 参数覆盖 RTL 常数、旧缓存被误认为实时数据和旧版验证结果误用。

## 通用 PYNQ 说明

`pynq-overlay-smoke/` 不依赖心电算法，也不绑定 PYNQ-Z2。它只要求 PYNQ Overlay 和 AXI-Lite 寄存器窗口，因此可复用到图像、控制、通信、传感器等 PYNQ 题目。它单独完成的是“最小可上板闭环”，不会假装覆盖 DMA 或中断场景。
