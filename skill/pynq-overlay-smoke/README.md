# PYNQ Overlay Smoke

| 文件或目录 | 用途 |
|---|---|
| `SKILL.md` | 适用场景、使用步骤、验证结果和失效条件 |
| `scripts/overlay_smoke.py` | PYNQ Overlay、AXI-Lite、ID、寄存器和控制位自动检查 |
| `scripts/test_overlay_smoke.py` | 无板卡后端测试，验证参数、同名文件、失败路径和 SCRATCH 回读 |
| `examples/register_map.json` | 本项目寄存器配置示例，其他项目可替换 |
| `examples/minimal_register_map.json` | 非心电项目的最小 SCRATCH 寄存配置 |
| `examples/validation_output.txt` | 模拟 PYNQ 后端测试的命令与通过输出 |
| `references/troubleshooting.md` | Overlay、地址、时钟、复位和旧缓存故障排查 |
