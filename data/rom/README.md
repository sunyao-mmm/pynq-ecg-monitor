ROM 文件夹说明（2026-10-21）
==========================================================

这里放的是可以用同一套 RTL 和同一个 1024x16 ROM IP 直接替换的数据。

目录内文件：

| 文件 | 用途 |
|---|---|
| `ecg_rom_100.coe` ... `ecg_rom_228.coe` | 15 个 MIT-BIH 记录的 1024×16 ROM 初始化数据 |
| `ecg_rom_208.hex` | 与默认 ROM 208 相同的纯十六进制数据，供 `tb_rom_long` 读取 |
| `make_coe.py` | 从 MIT-BIH format-212 原始文件重新生成任意记录 COE |
| `README.md` | 文件清单、数据窗口、生成方法和 Vivado 切换步骤 |

一、数据文件清单（共 15 个）
----------------------------------------------------------
  ecg_rom_100.coe  record 100，窗口起点 0，默认基准数据
  ecg_rom_101.coe  record 101，窗口起点 0
  ecg_rom_103.coe  record 103，窗口起点 0
  ecg_rom_105.coe  record 105，窗口起点 0
  ecg_rom_108.coe  record 108，窗口起点 0
  ecg_rom_111.coe  record 111，窗口起点 0
  ecg_rom_112.coe  record 112，窗口起点 0
  ecg_rom_116.coe  record 116，窗口起点 0
  ecg_rom_117.coe  record 117，窗口起点 0
  ecg_rom_118.coe  record 118，窗口起点 0
  ecg_rom_119.coe  record 119，窗口起点 549760，含两个连续室早
  ecg_rom_122.coe  record 122，窗口起点 0
  ecg_rom_123.coe  record 123，窗口起点 0
  ecg_rom_208.coe  record 208，窗口起点 611968，最终比特流默认使用
  ecg_rom_228.coe  record 228，窗口起点 0

其中 100、101、103、105、108、111、112、116、117、118、122、123、208、228
是批量验证报告中的 14 条时间轴可信记录；119 是额外的成对室早演示记录。

三个文件都是：
  - 1024 个 16 位字
  - 前 711 点有效，其余为补齐数据
  - RTL 只循环播放前 711 点
  - 采样率 250 Hz，来源为 MIT-BIH MLII 通道

二、数据生成方法
----------------------------------------------------------
  1. 读取 MIT-BIH format-212 原始数据
  2. 取 MLII 通道，做 (原始 ADC - 1024) * 5 的数值换算
  3. 从 360 Hz 重采样到 250 Hz
  4. 取 711 点，再用开头数据补齐到 1024 字

重新生成普通记录的示例（在 PowerShell 中执行）：

  $records = '100,101,103,105,108,111,112,116,117,118,122,123,228'.Split(',')
  foreach ($r in $records) {
      python make_coe.py --db <MIT-BIH目录> --record $r --start 0 `
          --out "ecg_rom_$r.coe"
  }

另外两个特殊窗口：

  python make_coe.py --db <MIT-BIH目录> --record 119 --start 549760 `
      --out ecg_rom_119.coe

  python make_coe.py --db <MIT-BIH目录> --record 208 --start 611968 `
      --out ecg_rom_208.coe

三、Vivado 中切换 ROM
----------------------------------------------------------
  1. 双击 blk_mem_gen_0
  2. 在 Other Options 的 Coefficient File 中选择需要的 COE
  3. 保持 Memory Depth = 1024、Width = 16
  4. Reset Output Products，再 Generate Output Products
  5. 重新生成比特流并导出 .hwh

