# Board

| 文件 | 用途 |
|---|---|
| `pynq_ecg.py` | 普通采集脚本，仅用于工程诊断和固定长度对照 |
| `pvc_check.py` | 辅助室早判别脚本，基于 QRS 宽度和 RR 关系 |
| `diagnose.py` | 故障体检脚本：检查 Overlay、ADS1292 帧数、ROM 和实时数据，不参与正常展示 |

网页是唯一产品界面。`pynq_ecg.py` 只保留为普通采集诊断工具；当出现波形常数、帧数不动或怀疑电极/前端异常时，再运行 `diagnose.py`。
