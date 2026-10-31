# RTL

| 文件 | 用途 |
|---|---|
| `notch_50hz.v` | 50 Hz 二阶 IIR 陷波，按实测 243.65 Hz 进样率设计 |
| `fir_bandpass.v` | 65 抽头 5-40 Hz 带通 FIR，串行 MAC |
| `clt_qrs.v` | 本项目的顶层工程中例化了 `clt_qrs`（曲线长度变换 QRS 检测）模块。由于该模块改编自第三方开源仓库（原作者未提供 LICENSE），为了尊重原作者版权，本公开仓库暂不提供该模块的源码，因此直接运行 `rebuild.tcl` 可能会提示找不到该模块。完整的工程源码（包含 CLT 模块）已打包作为附件直接提交给大赛组委会，仅供评审使用。目前我们正在联系原作者获取授权，若获得授权，后续会补充该模块源码。|
| `ecg_detect_top.v` | 串联陷波、FIR 和 CLT 检测链 |
| `heart_rate.v` | RR 间期、bpm、RR 中位数和异常 RR 状态 |
| `ads1292_spi.v` | ADS1292 SPI 配置、命令序列和 9 字节数据帧读取 |
| `ecg_core.v` | ROM/实时数据源选择、采样节拍、结果汇总、普通采集和连续环形缓存 |
| `ecg_axil.v` | AXI4-Lite 寄存器窗口，供 PS 读取状态和缓存 |
| `ads1292_pins.xdc` | PYNQ-Z2 外部端口到 FPGA 引脚约束 |

仿真文件不能加入 Design Sources；只有本目录的 RTL 和 XDC 进入硬件工程。
