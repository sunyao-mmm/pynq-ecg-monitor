---
name: golden-signal-compare
description: Compare detected event positions or intervals with a trusted golden reference and report TP, FP, FN, sensitivity, and positive predictive value.
---

# Golden Signal Compare

## 适用场景

用于任何“从信号中检测事件”的项目，例如心电 R 峰、脉冲边沿、传感器峰值、通信同步点。输入是一组参考位置和一组实际检测位置，输出可量化、可复查的 TP/FP/FN 与 Se/PPV。

## 使用方法

参考文件和检测文件都保存为整数列表，每行一个数，或一行用逗号分隔：

```bash
python scripts/compare_intervals.py \
  --reference reference.txt \
  --detected detected.txt \
  --tolerance 2
```

`tolerance` 的单位与输入相同，通常是采样点。心电若使用 150 ms、250 Hz，可设 `--tolerance 38`。

脚本在 `FP=0` 且 `FN=0` 时返回退出码 `0` 并输出 `RESULT: PASS`；出现误检或漏检时输出 `RESULT: FAIL` 并返回非零退出码，可直接作为 CI 或提交前门禁。

## 已验证效果

- record 100 黄金 R 峰 `53, 257, 460, 658` 对 RTL 结果 `54, 258, 461, 659`，容差 1 时得到 TP=4、FP=0、FN=0。
- 本项目批量验证还使用“参考时间轴对齐率”识别不可信记录；例如 record 121 的低对齐率不能直接当作算法失败。

## 失效条件

- 参考时间轴没有对齐、采样率不一致或存在整体偏移时，不能直接比较。
- 一个检测点可能匹配多个参考点，或事件本身允许合并/分裂时，需要先定义匹配规则。
- 单条记录的高分不能代表总体性能；必须同时保留逐条记录和汇总结果。
- 不能用它证明信号预处理正确；它只比较最终事件位置。

## 使用原则

先做黄金样例的小规模逐点比对，再做整库批量统计。对对齐率低、参考时间轴可疑的数据，应标注“仅列出”，不要和可信数据合并计算总指标。
