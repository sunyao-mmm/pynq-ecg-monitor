## =====================================================================
## PYNQ-Z2 (xc7z020clg400-1) : ADS1292 module on the Arduino header
## 【换脚版】2026-10-11
##
## 为什么要换脚：
##   之前的接线错位事故里，AR4（V15）和 AR5（T15）这两个脚最可能受过伤。
##   实测现象也正好指向它们：
##     * CS 在 FPGA 发时钟的时候一次都没有拉低  -> CS 送不出去
##     * 芯片的 DRDY 明明在跳，FPGA 却一帧都收不到 -> DRDY 传不回来
##   再加上"哪根线看起来悬空"每次测量都不一样（接触不良的典型特征），
##   所以这一版把 5 根信号线整体挪到 5 个全新的 AR 脚上：
##     - 避开可能受伤的旧脚
##     - 同时换上全新的孔（孔里的弹片也是新的，接触更可靠）
##
## 接线（模块丝印从上到下，接法和现在完全一样的顺序，只是整体右移 5 个孔）：
##
##   模块丝印   ->  PYNQ-Z2    FPGA 引脚   方向
##   DOUT       ->  AR7        U17         模块 -> FPGA (miso)
##   SCLK       ->  AR8        V17         FPGA -> 模块 (sclk)
##   CS         ->  AR9        V18         FPGA -> 模块 (cs_n)
##   DRDY       ->  AR10       T16         模块 -> FPGA (drdy_n)
##   DIN        ->  AR11       R17         FPGA -> 模块 (mosi)
##
##   5V  -> 电源排 5V      GND -> 电源排 GND       （这两根不用动）
##   AR2~AR6 这一版空着不用。
##
## 引脚号来自 PYNQ-Z2 官方板卡文件 pynq-z2/A.0/part0_pins.xml，
## 已核对：U17/V17/V18/T16/R17 在板子上没有被其它器件占用。
## =====================================================================

set_property -dict { PACKAGE_PIN U17  IOSTANDARD LVCMOS33 } [get_ports miso]
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 } [get_ports sclk]
set_property -dict { PACKAGE_PIN V18  IOSTANDARD LVCMOS33 } [get_ports cs_n]
set_property -dict { PACKAGE_PIN T16  IOSTANDARD LVCMOS33 } [get_ports drdy_n]
set_property -dict { PACKAGE_PIN R17  IOSTANDARD LVCMOS33 } [get_ports mosi]
