# Scripts

| 文件 | 用途 |
|---|---|
| `overlay_smoke.py` | 加载 Overlay，查找 IP 地址并执行 ID、写入回读、CAP_LEN 和 CTRL/STATUS 检查 |
| `test_overlay_smoke.py` | 用模拟 `pynq` 后端验证脚本逻辑，不需要开发板 |

脚本依赖板端 `pynq` Python 包；电脑侧只能检查语法，完整验证必须上板运行。
