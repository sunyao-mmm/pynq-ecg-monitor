## =====================================================================
## PYNQ-Z2 (xc7z020clg400-1) : ADS1292 module on the Arduino header
## =====================================================================

set_property -dict { PACKAGE_PIN U17  IOSTANDARD LVCMOS33 } [get_ports miso]
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 } [get_ports sclk]
set_property -dict { PACKAGE_PIN V18  IOSTANDARD LVCMOS33 } [get_ports cs_n]
set_property -dict { PACKAGE_PIN T16  IOSTANDARD LVCMOS33 } [get_ports drdy_n]
set_property -dict { PACKAGE_PIN R17  IOSTANDARD LVCMOS33 } [get_ports mosi]
