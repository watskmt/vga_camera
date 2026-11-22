# =============================================================================
# qspi_bd.tcl  -  fb_test BD に AXI Quad SPI (XIP) を追加する (段階 5: QSPI ブート)
# =============================================================================
# 追加:
#
#   axi_quad_spi_0 (XIP モード, 標準 SPI x1, Micron, STARTUPE2 内蔵)
#     AXI_FULL (XIP 読み出し)  0x6000_0000 (16 MB) = フラッシュの 0x00_0000〜0xFF_FFFF
#     AXI_LITE (XIP 設定)      0x44A2_0000 (64 KB)
#     ext_spi_clk = clk_wiz_0/pclk (25 MHz) → SCK 12.5 MHz (C_SCK_RATIO = 2)
#     SCK は STARTUPE2 経由で CCLK ピン (E9) へ。io0 / io1 / ss は外部ポート SPI_0
#
#   MicroBlaze-V のブートローダ (sw/boot) が電源投入時に XIP 窓からファームウェアを
#   DDR3 にコピーして起動する。読むだけなので XIP (メモリマップ読み出し) で足りる
#
# 生成される fb_test のポート (vga_top で IOBUF に接続):
#   SPI_0_io0_{i,o,t}  (DQ0 / MOSI, K17)
#   SPI_0_io1_{i,o,t}  (DQ1 / MISO, K18)
#   SPI_0_ss_{i,o,t}   (CS#, L13)
#   ※ DQ2 (WP#, L14) / DQ3 (HOLD#, M14) は vga_top で常に 1 を出す
#
# 使い方 (Vivado Tcl Console, プロジェクトを開いた状態で。eth_bd.tcl の後):
#   source {D:/xlinix/vga_camera/qspi_bd.tcl}
#   何度実行してもよい (追加済みなら何もしない)
# =============================================================================

open_bd_design [get_files fb_test.bd]
current_bd_design fb_test

if {[get_bd_cells -quiet axi_quad_spi_0] ne ""} {
    puts "qspi_bd.tcl: 既に追加済みのため何もしません"
    return
}
if {[get_bd_cells -quiet axi_uartlite_0] eq ""} {
    error "qspi_bd.tcl: 先に eth_bd.tcl を実行してください"
}

set defs [lsort [get_ipdefs -all -filter "NAME == axi_quad_spi"]]
set q [create_bd_cell -type ip -vlnv [lindex $defs end] axi_quad_spi_0]
set_property -dict [list \
    CONFIG.C_SPI_MEMORY             {2} \
    CONFIG.C_SPI_MODE               {0} \
    CONFIG.C_USE_STARTUP            {1} \
    CONFIG.C_USE_STARTUP_INT        {1} \
    CONFIG.C_XIP_MODE               {1} \
    CONFIG.C_TYPE_OF_AXI4_INTERFACE {1} \
    CONFIG.C_SCK_RATIO              {2} \
] $q

# AXI: smartconnect_0 (M_AXI_DP 側) に 2 つ追加
set sc [get_bd_cells smartconnect_0]
set n  [get_property CONFIG.NUM_MI $sc]
set_property CONFIG.NUM_MI [expr {$n + 2}] $sc
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M[format %02d $n]_AXI]           [get_bd_intf_pins axi_quad_spi_0/AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M[format %02d [expr {$n + 1}]]_AXI] [get_bd_intf_pins axi_quad_spi_0/AXI_FULL]

# クロック / リセット (AXI は SYSCLK 100 MHz, SPI は 25 MHz)
connect_bd_net [get_bd_pins clk_wiz_0/sysclk] [get_bd_pins axi_quad_spi_0/s_axi_aclk] [get_bd_pins axi_quad_spi_0/s_axi4_aclk]
connect_bd_net [get_bd_pins clk_wiz_0/pclk]   [get_bd_pins axi_quad_spi_0/ext_spi_clk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins axi_quad_spi_0/s_axi_aresetn] [get_bd_pins axi_quad_spi_0/s_axi4_aresetn]

# 外部ポート
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:spi_rtl:1.0 SPI_0
connect_bd_intf_net [get_bd_intf_pins axi_quad_spi_0/SPI_0] [get_bd_intf_ports SPI_0]

# アドレス (MicroBlaze-V の Data 空間のみ)
set mb_d [get_bd_addr_spaces microblaze_riscv_0/Data]
foreach seg [get_bd_addr_segs axi_quad_spi_0/*] {
    puts "qspi_bd.tcl: segment $seg"
}
set lite [get_bd_addr_segs -of_objects [get_bd_intf_pins axi_quad_spi_0/AXI_LITE]]
set full [get_bd_addr_segs -of_objects [get_bd_intf_pins axi_quad_spi_0/AXI_FULL]]
assign_bd_address -offset 0x44A20000 -range 64K -target_address_space $mb_d $lite -force
assign_bd_address -offset 0x60000000 -range 16M -target_address_space $mb_d $full -force

# S_AXI_CFG (cam_ddr_cfg) / axi_vip からは見せない
foreach sp [list [get_bd_addr_spaces -quiet S_AXI_CFG] [get_bd_addr_spaces -quiet axi_vip_0/Master_AXI]] {
    if {$sp eq ""} { continue }
    foreach s [list $lite $full] {
        catch { exclude_bd_addr_seg -target_address_space $sp $s }
    }
}

validate_bd_design
save_bd_design
generate_target all [get_files fb_test.bd]
puts "=== qspi_bd.tcl 完了: vga_top に SPI_0 (io0 / io1 / ss) と DQ2 / DQ3 = 1 を接続して合成してください ==="
