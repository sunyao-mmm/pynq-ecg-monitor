# Performance Summary

## 实现结果

| 指标 | 最终值 |
|---|---|
| 器件 | `xc7z020clg400-1` |
| PL 时钟 | 20 MHz |
| WNS | +0.036 ns |
| WHS | +0.039 ns |
| 时序失败端点 | 0 |
| LUT | 4,417（8.30%） |
| FF | 3,461（3.25%） |
| Block RAM | 4.5（3.21%） |
| DSP | 6（2.73%） |

## 功能验证

2026-10-26 使用最终 RTL 对 9 个 testbench 完成重新编译和仿真，全部 PASS。

| 验证 | 结果 |
|---|---|
| AXI 寄存器 | 27 项检查，PASS |
| ADS1292 SPI | PASS |
| 50 Hz 陷波 | PASS |
| 检测链 | TP=4、FP=0、FN=0 |
| 整链 | PASS |
| 心率状态机 | PASS |
| 连续环形缓存 | 普通模式停止、连续模式遍历和写指针回绕 PASS |
| RAM 映射 | 连续 4 次回绕后波形字、CLT 字和写地址保持对齐 PASS |
| 长 ROM 回归 | record 208 连续 105 圈，422 拍，`rr_bad=0` PASS |
| 网页数据处理 | 12 项离线检查全部 PASS |

## MIT-BIH

 使用官方 MIT-BIH Arrhythmia Database 1.0.0 重跑 23 条记录，其中 14 条参考时间轴可信：

- Se = 98.21%
- PPV = 98.43%
- 总标注心搏 = 30,447
- TP / FN / FP = 29,902 / 545 / 477


