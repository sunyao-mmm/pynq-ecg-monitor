---
name: vivado-report-audit
description: Audit Vivado timing and utilization reports against explicit thresholds and produce a reproducible PASS/FAIL summary for FPGA design review.
---

# Vivado Report Audit

## 适用场景

用于综合/实现完成后，自动检查最关键的提交数据：WNS、WHS、失败端点、LUT、寄存器、Block RAM 和 DSP 占用。适合在提交前、比较优化前后版本、或让陌生队伍快速判断一个 Vivado 报告能否作为基线时使用。

## 使用方法

```bash
python scripts/check_reports.py \
  --timing timing.rpt \
  --util util.rpt \
  --min-wns 0 \
  --min-whs 0 \
  --max-lut-pct 20 \
  --max-bram-pct 20 \
  --max-dsp-pct 20
```

脚本输出解析到的关键数值、每项 PASS/FAIL 和总结果。默认阈值只检查时序是否收敛；资源阈值应按具体题目设置，不能机械套用。

## 已验证效果

已使用本项目真实报告验证：

- `timing.rpt`：WNS 为 `0.036 ns`、WHS 为 `0.039 ns`、失败端点 `0`。
- `util.rpt`：LUT `4417 / 53200`、寄存器 `3461 / 106400`、Block RAM Tile `4.5 / 140`、DSP `6 / 220`。

这套检查对应项目从 100 MHz 时序失败迁移到 20 MHz 收敛的过程，可直接用于优化前后对比表。

## 失效条件

- 报告格式被 Vivado 新版本改变，或只提供了综合报告而没有实现报告。
- 设计包含多时钟域、生成时钟或异步约束时，单个 WNS 摘要不足以证明全部时序正确。
- 资源百分比低不等于性能好；必须结合采样率、延迟、吞吐量和功能正确性解释。
- 不能把本脚本当作时序约束审查工具，只做数值审计和提交前门禁。

## 解释原则

先确认“功能正确”，再比较“资源/时序”。为了追求更高时钟而增加大量流水线、DSP 或验证成本，若题目真实带宽很低，应明确说明这是不合理优化。
