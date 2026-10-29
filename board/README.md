# Board

| 文件 | 用途 |
|---|---|
| `ecg_bd_wrapper.bit` | 2026-10-26 最终比特流 |
| `ecg_bd_wrapper.hwh` | 与比特流配对使用的硬件描述文件，必须保持同名 |
| `ecg_web.py` | 主界面服务：加载 Overlay、连续环形缓存、网页 API 和 PS 分析 |
| `index.html` | 实时 ECG/CLT 滚动页面，支持 ROM/实时切换和正常/PVC 候选标记 |
| `run_web.sh` | 板端启动脚本；参数 `1` 为实时 ADS1292，`0` 为 MIT-BIH ROM |
| `WEB_README.md` | 网页功能、寄存器契约和板端运行说明 |
| `STATUS.md` | 最终时序、失败端点以及比特流/HWH 哈希 |

主演示流程：

```bash
sh run_web.sh 1   # 实时 ADS1292
sh run_web.sh 0   # ROM 演示
```

