# RTL

| 文件 | 用途 |
|---|---|
| `notch_50hz.v` | 50 Hz 二阶 IIR 陷波，按实测 243.65 Hz 进样率设计 |
| `fir_bandpass.v` | 65 抽头 5-40 Hz 带通 FIR，串行 MAC |
| `clt_qrs.v` | 由于未获得许可证，仅在比赛压缩包中提供|
| `ecg_detect_top.v` | 串联陷波、FIR 和 CLT 检测链 |
| `heart_rate.v` | RR 间期、bpm、RR 中位数和异常 RR 状态 |
| `ads1292_spi.v` | ADS1292 SPI 配置、命令序列和 9 字节数据帧读取 |
| `ecg_core.v` | ROM/实时数据源选择、采样节拍、结果汇总、普通采集和连续环形缓存 |
| `ecg_axil.v` | AXI4-Lite 寄存器窗口，供 PS 读取状态和缓存 |
| `ads1292_pins.xdc` | PYNQ-Z2 外部端口到 FPGA 引脚约束 |

仿真文件不能加入 Design Sources；只有本目录的 RTL 和 XDC 进入硬件工程。
