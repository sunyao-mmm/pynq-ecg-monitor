# Simulation

| 文件或目录 | 用途 |
|---|---|
| `testbench/` | 9 个可独立编译运行的 ModelSim/Vivado testbench |
| `logs/` | 最近一次全量 ModelSim 运行的原始日志 |
| `run_all.ps1` | 自动编译并运行全部 testbench，生成新的日志 |

运行方式：

```powershell
.\sim\run_all.ps1
```

脚本默认使用 `D:\modeltech64_10.4\win64`，可通过 `-ModelSimBin` 指定其他安装路径。

连续环形缓存、RAM 回绕和长 ROM 回归均包含在 `run_all.ps1` 中。`tb_rom_long` 会自动载入 `data/rom/ecg_rom_208.hex`。

如果仓库路径包含中文，ModelSim 10.4 会把仿真输入自动暂存到纯英文临时目录，并将最终日志写回 `sim/logs/`。
