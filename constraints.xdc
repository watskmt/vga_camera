## =============================================================================
## constraints.xdc  -  vga_top  /  Arty A7-35T
## =============================================================================
##
## Pmod ヘッダ配置:
##   JA (G13/B11/A11/D12/D13/B18/A18/K16) : VGA R[3:0] / G[3:0]     ┐ Digilent
##   JB (E15/E16/D15/C15/J17/J18/K15/J15) : VGA B[3:0] / HS / VS    ┘ PmodVGA
##   JC (U12/V12/V10/V11/U14/V14/T13/U13) : OV7670 制御信号 + D0
##   JD (D4 /D3 /F4 /F3 /E2 /D2 /H2 /G2 ) : OV7670 PCLK + D1-D7
##
## Pmod 12 ピン コネクタ ピン番号対応:
##   上段 pin1-pin4 = [0]-[3]  下段 pin7-pin10 = [4]-[7]
## =============================================================================

## ---------- スライドスイッチ ----------
## SW0: カラーバー切り替え (High=カラーバー / Low=カメラ映像)
set_property PACKAGE_PIN A8       [get_ports sw_test]
set_property IOSTANDARD  LVCMOS33 [get_ports sw_test]
## SW1: cam_d 上位4ビット直接出力 (High=RAW / Low=通常, SW0より優先)
set_property PACKAGE_PIN C11      [get_ports sw_raw]
set_property IOSTANDARD  LVCMOS33 [get_ports sw_raw]
## SW2: テストパターン種別 (High=モノクロ階調 / Low=RGBカラーバー)
set_property PACKAGE_PIN C10      [get_ports sw_mono]
set_property IOSTANDARD  LVCMOS33 [get_ports sw_mono]
## SW3: cam_d テストパターン挿入 (High=0xF0/0x00→0x00/0xF0→0x00/0x0F 循環)
set_property PACKAGE_PIN A10      [get_ports sw3]
set_property IOSTANDARD  LVCMOS33 [get_ports sw3]

## ---------- システムクロック (100 MHz) ----------
set_property PACKAGE_PIN E3       [get_ports clk]
set_property IOSTANDARD  LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk [get_ports clk]

## ---------- リセットボタン : BTN0 (D9, Active High) ----------
set_property PACKAGE_PIN D9       [get_ports btn_rst]
set_property IOSTANDARD  LVCMOS33 [get_ports btn_rst]

## ---------- ステータス LED (LD0-LD3) ----------
## led[0]=PLL lock  led[1]=SIO test pass  led[2]=SIO test fail  led[3]=reset
set_property PACKAGE_PIN H5       [get_ports {led[0]}]
set_property PACKAGE_PIN J5       [get_ports {led[1]}]
set_property PACKAGE_PIN T9       [get_ports {led[2]}]
set_property PACKAGE_PIN T10      [get_ports {led[3]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {led[*]}]

## =============================================================================
## OV7670 カメラ
## =============================================================================

## =============================================================================
## OV7670 カメラ ピン配置
## =============================================================================
## cam_pclk は Pmod JD pin1 (D4) に接続する。
## JD には CCIO ピンがないため CLOCK_DEDICATED_ROUTE FALSE が必要。
## 25 MHz 動作では問題なし。
## =============================================================================

## ---------- Pmod JD : OV7670 PCLK + D1-D7 ----------
set_property PACKAGE_PIN D4       [get_ports cam_pclk]    ;# JD pin1  ← OV7670 PCLK
set_property PACKAGE_PIN D3       [get_ports {cam_d[1]}]  ;# JD pin2  ← OV7670 D1
set_property PACKAGE_PIN F4       [get_ports {cam_d[2]}]  ;# JD pin3  ← OV7670 D2
set_property PACKAGE_PIN F3       [get_ports {cam_d[3]}]  ;# JD pin4  ← OV7670 D3
set_property PACKAGE_PIN E2       [get_ports {cam_d[4]}]  ;# JD pin7  ← OV7670 D4
set_property PACKAGE_PIN D2       [get_ports {cam_d[5]}]  ;# JD pin8  ← OV7670 D5
set_property PACKAGE_PIN H2       [get_ports {cam_d[6]}]  ;# JD pin9  ← OV7670 D6
set_property PACKAGE_PIN G2       [get_ports {cam_d[7]}]  ;# JD pin10 ← OV7670 D7
set_property IOSTANDARD  LVCMOS33 [get_ports cam_pclk]
set_property IOSTANDARD  LVCMOS33 [get_ports {cam_d[*]}]

## ---------- Pmod JC : OV7670 制御信号 + D0 ----------
set_property PACKAGE_PIN U12      [get_ports cam_xclk]    ;# JC pin1  → OV7670 XCLK
set_property PACKAGE_PIN V12      [get_ports {cam_d[0]}]  ;# JC pin2  ← OV7670 D0
set_property PACKAGE_PIN V10      [get_ports cam_href]    ;# JC pin3  ← OV7670 HREF
set_property PACKAGE_PIN V11      [get_ports cam_vsync]   ;# JC pin4  ← OV7670 VSYNC
set_property PACKAGE_PIN U14      [get_ports cam_sioc]    ;# JC pin7  → OV7670 SIOC
set_property PACKAGE_PIN V14      [get_ports cam_siod]    ;# JC pin8  ↔ OV7670 SIOD
set_property PACKAGE_PIN T13      [get_ports cam_rst_n]   ;# JC pin9  → OV7670 RESET
set_property PACKAGE_PIN U13      [get_ports cam_pwdn]    ;# JC pin10 → OV7670 PWDN
set_property IOSTANDARD  LVCMOS33 [get_ports {cam_xclk cam_href cam_vsync}]
set_property IOSTANDARD  LVCMOS33 [get_ports {cam_sioc cam_rst_n cam_pwdn}]

## SIOD: オープンドレイン (基板上 4.7kΩ プルアップ想定)
set_property IOSTANDARD  LVCMOS33 [get_ports cam_siod]
set_property PULLUP      true     [get_ports cam_siod]

## OV7670 PCLK クロック制約
## JD に CCIO ピンがないため CLOCK_DEDICATED_ROUTE FALSE が必要
create_clock -period 40.000 -name cam_pclk [get_ports cam_pclk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cam_pclk_IBUF]

## =============================================================================
## VGA 出力 (Digilent PmodVGA — JA + JB 隣接スロット)
## =============================================================================

## ---------- Pmod JA : R[3:0] (pin1-4) / B[3:0] (pin7-10) ----------
## 実測: JA pin7-10 は VGA Blue 物理チャンネルに接続
set_property PACKAGE_PIN G13      [get_ports {vga_r[0]}]  ;# JA pin1
set_property PACKAGE_PIN B11      [get_ports {vga_r[1]}]  ;# JA pin2
set_property PACKAGE_PIN A11      [get_ports {vga_r[2]}]  ;# JA pin3
set_property PACKAGE_PIN D12      [get_ports {vga_r[3]}]  ;# JA pin4
set_property PACKAGE_PIN D13      [get_ports {vga_b[0]}]  ;# JA pin7  → VGA Blue
set_property PACKAGE_PIN B18      [get_ports {vga_b[1]}]  ;# JA pin8
set_property PACKAGE_PIN A18      [get_ports {vga_b[2]}]  ;# JA pin9
set_property PACKAGE_PIN K16      [get_ports {vga_b[3]}]  ;# JA pin10
set_property IOSTANDARD  LVCMOS33 [get_ports {vga_r[*] vga_b[*]}]

## ---------- Pmod JB : G[3:0] (pin1-4) / HS (pin7) / VS (pin8) ----------
## 実測: JB pin1-4 は VGA Green 物理チャンネルに接続
set_property PACKAGE_PIN E15      [get_ports {vga_g[0]}]  ;# JB pin1  → VGA Green
set_property PACKAGE_PIN E16      [get_ports {vga_g[1]}]  ;# JB pin2
set_property PACKAGE_PIN D15      [get_ports {vga_g[2]}]  ;# JB pin3
set_property PACKAGE_PIN C15      [get_ports {vga_g[3]}]  ;# JB pin4
set_property PACKAGE_PIN J17      [get_ports vga_hs]      ;# JB pin7
set_property PACKAGE_PIN J18      [get_ports vga_vs]      ;# JB pin8
set_property IOSTANDARD  LVCMOS33 [get_ports {vga_g[*] vga_hs vga_vs}]

## =============================================================================
## タイミング例外
## =============================================================================
## cam_pclk は sys_clk / pclk_mmcm と非同期クロックドメイン
##
## -include_generated_clocks: sys_clk から MMCM で生成された pclk_mmcm を
##   同グループに含め、pclk_mmcm ↔ cam_pclk 間のタイミング解析を無効化する。
##   これを省略すると Vivado が pclk_mmcm ↔ cam_pclk を「関連クロック」と
##   みなし Critical Warning が発生する。
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks cam_pclk]

# =============================================================================
# DDR3 キャリブ完了信号 (MIG ui_clk) → pclk 同期化 FF 1 段目は非同期
# =============================================================================
set_false_path -to [get_cells {ddr3_calib_sync_reg[0]}]

# =============================================================================
# Debug Hub クロック
#   既定では ILA と同じ pclk (25 MHz) に接続されるが、debug hub クロックは
#   JTAG クロックの 2.5 倍以上必要 (Digilent 既定 JTAG = 15 MHz) なので
#   100 MHz の clk100 に接続する。
# =============================================================================
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false    [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1           [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk100]

# =============================================================================
# コンフィギュレーション / QSPI フラッシュ起動 (MCS 用)
#   MCS 生成時は write_cfgmem -interface SPIx4 を指定すること
# =============================================================================
set_property CFGBVS VCCO                      [current_design]
set_property CONFIG_VOLTAGE 3.3               [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33   [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE  [current_design]
