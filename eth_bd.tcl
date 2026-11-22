# =============================================================================
# eth_bd.tcl  -  fb_test BD に Ethernet (MII) と MicroBlaze-V の DDR3 実行環境を追加する
# =============================================================================
# 追加・変更:
#
#   microblaze_riscv_0
#     - 命令 / データキャッシュ (各 32 KB, ライン 8 ワード, データはライトバック) を有効化
#       (段階 4 で 8 KB / 4 ワードから拡大。追加済みの BD にも適用する)
#       キャッシュ範囲 = DDR3 0x8000_0000〜0x87FF_FFFF (128 MB)
#     - M_AXI_IC / M_AXI_DC ──► smartconnect_1 (S02 / S03) ──► MIG
#     - 乗除算命令 (RV32M) を有効化
#     - INTERRUPT ◄── axi_intc_0
#
#   smartconnect_0 (M_AXI_DP 側, SYSCLK 100 MHz) に周辺を追加:
#     M02: axi_ethernetlite_0  0x40E0_0000 (64 KB)  MII + MDIO, 送受信とも 2 バッファ
#     M03: axi_timer_0         0x41C0_0000 (64 KB)  lwIP の周期処理用
#     M04: axi_intc_0          0x4120_0000 (64 KB)  {timer, ethernetlite} → MicroBlaze-V
#     M05: axi_uartlite_0      0x4060_0000 (64 KB)  USB-UART (115200 bps, 8N1)
#
#   割り込み (axi_intc_0 の intr[1:0]):
#     [0] axi_ethernetlite_0/ip2intc_irpt
#     [1] axi_timer_0/interrupt
#
#   MicroBlaze-V から見たメモリ:
#     0x0000_0000  LMB BRAM 16 KB (ベクタ / 起動用)
#     0x8000_0000  DDR3 128 MB (0x8000_0000〜 900 KB はカメラのフレームバッファ。
#                  プログラム・ヒープは 0x8100_0000 以降に置く)
#
# 生成される fb_test のポート (vga_top で接続):
#   MII_{col, crs, rst_n, rx_clk, rx_dv, rx_er, rxd[3:0], tx_clk, tx_en, txd[3:0]}
#   MDIO_{mdc, mdio_i, mdio_o, mdio_t}   (IOBUF は vga_top 側)
#   UART_{rxd, txd}
#
# 使い方 (Vivado Tcl Console, プロジェクトを開いた状態で。cam_ddr_bd.tcl の後):
#   source {D:/xlinix/vga_camera/eth_bd.tcl}
#   何度実行してもよい (追加済みなら何もしない)
# =============================================================================

open_bd_design [get_files fb_test.bd]
current_bd_design fb_test

# MicroBlaze-V の例外を有効にする (追加済みの BD にも適用する)
#   例外がすべて無効 (C_ILL_INSTR_EXCEPTION = 0, C_MISALIGNED_EXCEPTIONS = 0) だと
#   mret が何もしない命令として素通りされ、割り込みから戻れずに暴走する (実機で確認)
proc eth_bd_mbv_exceptions {} {
    set mb [get_bd_cells microblaze_riscv_0]
    if {[get_property CONFIG.C_ILL_INSTR_EXCEPTION $mb] == 0 || [get_property CONFIG.C_MISALIGNED_EXCEPTIONS $mb] == 0} {
        set_property -dict [list CONFIG.C_ILL_INSTR_EXCEPTION {1} CONFIG.C_MISALIGNED_EXCEPTIONS {1}] $mb
        puts "eth_bd.tcl: MicroBlaze-V の例外 (不正命令 BASIC / misaligned) を有効にしました"
        return 1
    }
    return 0
}

# MicroBlaze-V のキャッシュを各 32 KB, ライン 8 ワードにする (追加済みの BD にも適用する)
#   DDR3 のキャッシュミス 1 回が約 2.3 µs かかり、Web の画像転送はメモリの遅さで決まるため
proc eth_bd_mbv_caches {} {
    set mb [get_bd_cells microblaze_riscv_0]
    set want [list CONFIG.C_ICACHE_BYTE_SIZE 32768 CONFIG.C_ICACHE_LINE_LEN 8 \
                   CONFIG.C_DCACHE_BYTE_SIZE 32768 CONFIG.C_DCACHE_LINE_LEN 8]
    set diff 0
    foreach {k v} $want {
        if {[get_property $k $mb] != $v} { set diff 1 }
    }
    if {$diff} {
        set_property -dict $want $mb
        puts "eth_bd.tcl: MicroBlaze-V のキャッシュを各 32 KB / ライン 8 ワードにしました"
    }
    return $diff
}

if {[get_bd_cells -quiet axi_ethernetlite_0] ne ""} {
    set changed [eth_bd_mbv_exceptions]
    if {[eth_bd_mbv_caches]} { set changed 1 }
    if {$changed} {
        validate_bd_design
        save_bd_design
        generate_target all [get_files fb_test.bd]
    } else {
        puts "eth_bd.tcl: 既に変更済みのため何もしません"
    }
    return
}
eth_bd_mbv_exceptions
if {[get_bd_intf_ports -quiet S_AXI_CFG] eq ""} {
    error "eth_bd.tcl: 先に cam_ddr_bd.tcl を実行してください"
}

# 最新版の IP 定義 (VLNV) を名前で探す
proc ip_vlnv {name} {
    set defs [lsort [get_ipdefs -all -filter "NAME == $name && UPGRADE_VERSIONS == \"\""]]
    if {$defs eq ""} { set defs [lsort [get_ipdefs -all -filter "NAME == $name"]] }
    if {$defs eq ""} { error "IP が見つかりません: $name" }
    return [lindex $defs end]
}

set clk  [get_bd_pins clk_wiz_0/sysclk]
set rstn [get_bd_pins proc_sys_reset_0/peripheral_aresetn]
set mb   [get_bd_cells microblaze_riscv_0]

# -----------------------------------------------------------------------------
# 1. MicroBlaze-V: キャッシュ (DDR3) / 乗除算 / 割り込み
# -----------------------------------------------------------------------------
set_property -dict [list \
    CONFIG.C_USE_ICACHE            {1} \
    CONFIG.C_ICACHE_BASEADDR       {0x0000000080000000} \
    CONFIG.C_ICACHE_HIGHADDR       {0x0000000087FFFFFF} \
    CONFIG.C_ICACHE_BYTE_SIZE      {32768} \
    CONFIG.C_ICACHE_LINE_LEN       {8} \
    CONFIG.C_USE_DCACHE            {1} \
    CONFIG.C_DCACHE_BASEADDR       {0x0000000080000000} \
    CONFIG.C_DCACHE_HIGHADDR       {0x0000000087FFFFFF} \
    CONFIG.C_DCACHE_BYTE_SIZE      {32768} \
    CONFIG.C_DCACHE_LINE_LEN       {8} \
    CONFIG.C_DCACHE_USE_WRITEBACK  {1} \
    CONFIG.C_USE_MULDIV            {1} \
] $mb

set_property CONFIG.NUM_SI {4} [get_bd_cells smartconnect_1]
connect_bd_intf_net [get_bd_intf_pins microblaze_riscv_0/M_AXI_IC] [get_bd_intf_pins smartconnect_1/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins microblaze_riscv_0/M_AXI_DC] [get_bd_intf_pins smartconnect_1/S03_AXI]

# -----------------------------------------------------------------------------
# 2. 周辺 IP
# -----------------------------------------------------------------------------
set eth [create_bd_cell -type ip -vlnv [ip_vlnv axi_ethernetlite] axi_ethernetlite_0]
set_property -dict [list \
    CONFIG.C_INCLUDE_MDIO              {1} \
    CONFIG.C_TX_PING_PONG              {1} \
    CONFIG.C_RX_PING_PONG              {1} \
    CONFIG.C_INCLUDE_INTERNAL_LOOPBACK {0} \
    CONFIG.C_S_AXI_PROTOCOL            {AXI4LITE} \
] $eth

set tmr [create_bd_cell -type ip -vlnv [ip_vlnv axi_timer] axi_timer_0]
set_property CONFIG.enable_timer2 {0} $tmr

set intc [create_bd_cell -type ip -vlnv [ip_vlnv axi_intc] axi_intc_0]
set_property -dict [list \
    CONFIG.C_IRQ_CONNECTION {0} \
    CONFIG.C_HAS_FAST       {0} \
] $intc

set uart [create_bd_cell -type ip -vlnv [ip_vlnv axi_uartlite] axi_uartlite_0]
set_property -dict [list \
    CONFIG.C_BAUDRATE  {115200} \
    CONFIG.C_DATA_BITS {8} \
    CONFIG.C_USE_PARITY {0} \
] $uart

# 割り込みをまとめる (xlconcat / ilconcat のどちらか使える方)
set cc_def ""
foreach n {xlconcat ilconcat} {
    set d [lsort [get_ipdefs -all -filter "NAME == $n"]]
    if {$d ne ""} { set cc_def [lindex $d end]; break }
}
if {$cc_def eq ""} { error "xlconcat / ilconcat が見つかりません" }
set irq [create_bd_cell -type ip -vlnv $cc_def irq_concat]
set_property CONFIG.NUM_PORTS {2} $irq

# -----------------------------------------------------------------------------
# 3. AXI (smartconnect_0: M_AXI_DP / S_AXI_CFG / axi_vip 側)
# -----------------------------------------------------------------------------
set_property CONFIG.NUM_MI {6} [get_bd_cells smartconnect_0]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M02_AXI] [get_bd_intf_pins axi_ethernetlite_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M03_AXI] [get_bd_intf_pins axi_timer_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M04_AXI] [get_bd_intf_pins axi_intc_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M05_AXI] [get_bd_intf_pins axi_uartlite_0/S_AXI]

# クロック / リセット (すべて SYSCLK 100 MHz)
connect_bd_net $clk  [get_bd_pins axi_ethernetlite_0/s_axi_aclk] [get_bd_pins axi_timer_0/s_axi_aclk] \
                     [get_bd_pins axi_intc_0/s_axi_aclk] [get_bd_pins axi_uartlite_0/s_axi_aclk]
connect_bd_net $rstn [get_bd_pins axi_ethernetlite_0/s_axi_aresetn] [get_bd_pins axi_timer_0/s_axi_aresetn] \
                     [get_bd_pins axi_intc_0/s_axi_aresetn] [get_bd_pins axi_uartlite_0/s_axi_aresetn]

# 割り込み
connect_bd_net [get_bd_pins axi_ethernetlite_0/ip2intc_irpt] [get_bd_pins irq_concat/In0]
connect_bd_net [get_bd_pins axi_timer_0/interrupt]           [get_bd_pins irq_concat/In1]
connect_bd_net [get_bd_pins irq_concat/dout]                 [get_bd_pins axi_intc_0/intr]
connect_bd_intf_net [get_bd_intf_pins axi_intc_0/interrupt]  [get_bd_intf_pins microblaze_riscv_0/INTERRUPT]

# -----------------------------------------------------------------------------
# 4. 外部ポート (MII / MDIO / UART)
# -----------------------------------------------------------------------------
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mii_rtl:1.0  MII
connect_bd_intf_net [get_bd_intf_pins axi_ethernetlite_0/MII]  [get_bd_intf_ports MII]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO
connect_bd_intf_net [get_bd_intf_pins axi_ethernetlite_0/MDIO] [get_bd_intf_ports MDIO]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:uart_rtl:1.0 UART
connect_bd_intf_net [get_bd_intf_pins axi_uartlite_0/UART]     [get_bd_intf_ports UART]

# -----------------------------------------------------------------------------
# 5. アドレス割り当て (MicroBlaze-V の Data / Instruction 空間)
# -----------------------------------------------------------------------------
set mb_d [get_bd_addr_spaces microblaze_riscv_0/Data]
set mb_i [get_bd_addr_spaces microblaze_riscv_0/Instruction]
set ddr  [get_bd_addr_segs -of_objects [get_bd_intf_pins fb_test_mig_7series_1_0/S_AXI]]

assign_bd_address -offset 0x40E00000 -range 64K  -target_address_space $mb_d [get_bd_addr_segs axi_ethernetlite_0/S_AXI/Reg] -force
assign_bd_address -offset 0x41C00000 -range 64K  -target_address_space $mb_d [get_bd_addr_segs axi_timer_0/S_AXI/Reg] -force
assign_bd_address -offset 0x41200000 -range 64K  -target_address_space $mb_d [get_bd_addr_segs axi_intc_0/S_AXI/Reg] -force
assign_bd_address -offset 0x40600000 -range 64K  -target_address_space $mb_d [get_bd_addr_segs axi_uartlite_0/S_AXI/Reg] -force
assign_bd_address -offset 0x80000000 -range 128M -target_address_space $mb_d $ddr -force
assign_bd_address -offset 0x80000000 -range 128M -target_address_space $mb_i $ddr -force

# S_AXI_CFG (cam_ddr_cfg) / axi_vip からは新しい周辺を見せない
foreach sp [list [get_bd_addr_spaces S_AXI_CFG] [get_bd_addr_spaces axi_vip_0/Master_AXI]] {
    foreach seg {axi_ethernetlite_0/S_AXI/Reg axi_timer_0/S_AXI/Reg axi_intc_0/S_AXI/Reg axi_uartlite_0/S_AXI/Reg} {
        set s [get_bd_addr_segs -quiet $seg]
        if {$s ne ""} { catch { exclude_bd_addr_seg -target_address_space $sp $s } }
    }
}

# -----------------------------------------------------------------------------
# 6. 検証・保存・出力生成
# -----------------------------------------------------------------------------
validate_bd_design
save_bd_design
generate_target all [get_files fb_test.bd]
puts "=== eth_bd.tcl 完了: vga_top に MII / MDIO / UART を接続して合成してください ==="
