# Testbench

| 文件 | 覆盖内容 |
|---|---|
| `tb_ecg_axil.v` | AXI 寄存器、CTRL/STATUS、CAP_LEN、缓存读回和 `ctrl_src` |
| `tb_ads1292_spi.v` | SPI 命令、寄存器配置、DRDY 帧和 24→16 位转换 |
| `tb_notch_50hz.v` | 50 Hz 衰减、10 Hz 通过和阶跃稳定性 |
| `tb_ecg_detect.v` | 陷波、FIR、CLT 检测链的黄金峰值 |
| `tb_ecg_core.v` | ROM、检测、心率和缓存整链 |
| `tb_heart_rate.v` | 正常 RR、异常 RR 和心率窗口边界 |
| `tb_ecg_continuous.v` | 普通采集停止、连续环形缓存和写指针遍历 |
| `tb_ring_memory.v` | 连续模式下波形、CLT 字和写地址多次回绕仍对齐 |
| `tb_rom_long.v` | ROM 连续循环和双阈值长 RR 漏检恢复回归 |

`tb_ecg_axil.v` 必须和 `src/rtl/ecg_axil.v` 一起编译。其余依赖关系见 `sim/run_all.ps1`。
