# PYNQ Overlay Troubleshooting

## 症状与优先检查

| 现象 | 首先检查 | 典型原因 |
|---|---|---|
| Overlay 加载失败 | `.bit` 与 `.hwh` 是否同名同目录 | 导出 Hardware 时没有包含 bitstream，或文件名被改坏 |
| `ip_dict` 找不到 IP | Vivado Address Editor 和 Overlay 是否来自同一工程 | 板上是旧 `.bit/.hwh`，或 IP 名称配置写错 |
| 寄存器一直读 0 | IP 是否有时钟和复位 | FCLK 未启用、BD 连线断开、PS 未正常启动 |
| 写入不生效 | 是否先 soft reset，是否被 BD 参数覆盖 | RTL 常数与 Block Design 参数不一致，或寄存器只读/自清零 |
| 同名 `.bit` 替换后仍跑旧逻辑 | 是否强制重新下载 Overlay | Jupyter 内核或 PYNQ 缓存沿用旧 Overlay；重启内核或调用 `download()` |
| 一读就挂住 | AXI 基址、时钟和地址范围 | 地址错误、外设未时钟化、AXI-Lite 握手没有响应 |

## 已验证的排查顺序

1. 只验证 Overlay 是否加载。
2. 只验证 IP 是否出现在 `ip_dict`。
3. 只读 ID。
4. 单独测 SCRATCH 写回读。
5. 再测业务寄存器 CAP_LEN。
6. 最后测 CTRL/STATUS 联动。

把步骤拆开后，能明确区分“文件不匹配”“地址不对”“只读配置”“实际业务逻辑没跑”。
