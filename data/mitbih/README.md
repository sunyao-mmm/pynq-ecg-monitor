# MIT-BIH Validation

该目录保存批量验证脚本、运行日志和最终结果。

最终重跑日期为 2026-10-26，使用官方 MIT-BIH Arrhythmia Database 1.0.0，共检查 23 条记录；其中 14 条参考时间轴可信，汇总结果为 Se 98.21%、PPV 98.43%。

| 文件 | 用途 |
|---|---|
| `validate_mitdb.py` | 逐条记录复刻 PL 检测链并统计 TP/FN/FP、Se 和 PPV |
| `verification_results.md` | 14 条时间轴可信记录的最终汇总表 |
| `verification_run.log` | 2026-10-26 最终双阈值版本的逐记录运行日志 |
| `README.md` | 本目录使用方法 |

```bash
python validate_mitdb.py \
  --db <MIT-BIH database directory> \
  --out verification_results.md
```

数据库目录必须包含 `100.dat`、`100.atr`、`100.hea` 等原始文件。脚本会先判断参考时间轴是否对齐；对齐失败的记录只列出，不计入总体 Se/PPV。

自校验：

```bash
python validate_mitdb.py \
  --db <MIT-BIH database directory> \
  --check100
```

期望 record 100 的前几个 R 峰为 `54 / 258 / 461 / 658`。
