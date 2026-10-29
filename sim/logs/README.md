# Simulation Logs

| 文件 | 对应用例 |
|---|---|
| `tb_ecg_axil.log` | AXI 寄存器和缓存读回，27 项检查 |
| `tb_ads1292_spi.log` | SPI 配置和帧读取，14 项检查 |
| `tb_notch_50hz.log` | 陷波器，3 项检查 |
| `tb_ecg_detect.log` | 检测链，4 个峰值且 TP=4、FP=0、FN=0 |
| `tb_ecg_core.log` | 整链，22 项检查 |
| `tb_heart_rate.log` | 心率状态机 |
| `tb_ecg_continuous.log` | 普通停止、连续模式和指针遍历，PASS |
| `tb_ring_memory.log` | 连续缓存 4 次回绕后仍对齐，PASS |
| `tb_rom_long.log` | record 208 长循环，422 拍、`rr_bad=0`，PASS |

日志由 `sim/run_all.ps1` 生成；重新运行会覆盖同名日志。

全部 9 个日志已于 2026-10-26 22:48 在纯英文路径下使用最终 RTL 重新生成，ModelSim 10.4 的编译、仿真和结果判定均为 PASS。最终提交以 `report/performance/performance_summary.md` 汇总的结果为准。
