# Examples

| 文件 | 用途 |
|---|---|
| `reference_record100.txt` | MIT-BIH record 100 的黄金 R 峰位置 |
| `detected_record100.txt` | RTL 对应的检测 R 峰位置 |
| `detected_record100_fail.txt` | 故意缺少一个峰值的失败样例，用于验证非零退出码 |

使用 `--tolerance 1` 运行应得到 TP=4、FP=0、FN=0。
