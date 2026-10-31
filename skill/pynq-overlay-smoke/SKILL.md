---
name: pynq-overlay-smoke
description: Validate a PYNQ Overlay and AXI-Lite register window on board with file pairing, IP discovery, ID, round-trip, capture length, and control/status checks.
---

# PYNQ Overlay Smoke

## 适用场景

用于刚生成 `.bit` 和 `.hwh`、准备第一次上板的 PYNQ 项目。它先证明 Overlay、IP 地址、AXI-Lite 读写和复位/运行控制是通的，再让开发者去查算法或外设。

## 使用方法

把 `scripts/overlay_smoke.py` 和 `examples/register_map.json` 复制到板上同一目录，按实际寄存器修改 JSON：

```bash
python overlay_smoke.py \
  --bit ecg_bd_wrapper.bit \
  --hwh ecg_bd_wrapper.hwh \
  --config register_map.json
```

配置中的偏移量和值支持十进制或 `0x` 十六进制。脚本会：

1. 检查 `.bit` 和 `.hwh` 同名且存在。
2. 加载 Overlay。
3. 从 `ip_dict` 找到目标 IP 和物理地址。
4. 读取 ID 并与期望值比较。
5. 对 SCRATCH、CAP_LEN 等寄存器做写入回读。
6. 可选地写 CTRL，再读 STATUS，确认运行位联动。
7. 输出逐项 PASS/FAIL 和最终 `RESULT: PASS` 或 `RESULT: FAIL`。

换到非心电项目时，可从 `examples/minimal_register_map.json` 开始，只保留目标 IP 名称和 SCRATCH 回读项。`scripts/test_overlay_smoke.py` 使用模拟 PYNQ 后端验证脚本自身的参数检查、同名文件检查、ID 失败和写回读逻辑，无需开发板：

```bash
python scripts/test_overlay_smoke.py
```

## 已验证效果

脚本逻辑已通过无板卡模拟后端测试，共 3 项检查，结果为 `RESULT: PASS`。测试覆盖参数检查、文件同名检查、ID 校验和寄存器写入回读逻辑。

## 失效条件

- 目标 IP 没有 AXI-Lite 寄存器窗口。
- 项目必须依赖 DMA、AXI-Stream、中断或缓存一致性；本脚本不覆盖这些路径。
- 板上 PYNQ 版本无法加载该 Overlay，或 `.bit/.hwh` 不匹配。
- 寄存器会自清零、只读或写入有副作用；此时只能使用 ID/状态检查，不能做通用 round-trip。

## 排查方法

先读 [references/troubleshooting.md](references/troubleshooting.md)。最优先检查 `.bit/.hwh` 同名、IP 是否真的出现在 `ip_dict`、FCLK 是否启用，以及 Vivado 的 Address Editor 是否与脚本配置一致。
