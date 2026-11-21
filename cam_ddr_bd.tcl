# =============================================================================
# cam_ddr_bd.tcl  -  fb_test BD をカメラ映像の DDR3 バッファ用に変更する
# =============================================================================
# 変更前:  v_tpg_0 ──AXIS──► axi_vdma_0 S2MM
# 変更後:  v_tpg_0 ──AXIS──► [M_AXIS_TPG] ──► (vga_top / cam_ddr: TPG / カメラ切替)
#                                                         │
#          axi_vdma_0 S2MM ◄── [S_AXIS_VID] ◄─────────────┘
#
#          [S_AXI_CFG] (AXI4-Lite) ──► smartconnect_0 S02 ──► VDMA / TPG レジスタ
#             (cam_ddr 内の cam_ddr_cfg が起動時に VDMA と TPG を設定する)
#
#          [SYSCLK]   = clk_wiz_0/sysclk (100 MHz)         ─ 上記 3 ポートのクロック
#          [SYSRST_N] = proc_sys_reset_0/peripheral_aresetn ─ 同リセット
#          [ACTIVE_VIDEO] = v_axi4s_vid_out_0/vid_active_video (ブランキング中の RGB を 0 にする用)
#
# アドレス (S_AXI_CFG から見た空間, MicroBlaze-V と同じ):
#   axi_vdma_0 S_AXI_LITE : 0x44A0_0000 (64 KB)
#   v_tpg_0    s_axi_CTRL : 0x44A1_0000 (64 KB)
#
# 生成される fb_test のポート (vga_top で接続):
#   SYSCLK, SYSRST_N
#   M_AXIS_TPG_{tdata[23:0],tvalid,tready,tlast,tuser,tkeep,tstrb,tid,tdest}
#   S_AXIS_VID_{tdata[23:0],tvalid,tready,tlast,tuser,tkeep[2:0]}  (tkeep は VDMA から伝搬)
#   S_AXI_CFG_{aw,w,b,ar,r}*  (awprot/arprot 付き)
#
# 使い方 (Vivado Tcl Console, プロジェクトを開いた状態で。1 回だけ実行):
#   source {D:/xlinix/vga_camera/cam_ddr_bd.tcl}
# =============================================================================

# RTL (cam_ddr.v) をプロジェクトに追加
set script_dir [file dirname [file normalize [info script]]]
if {[get_files -quiet */cam_ddr.v] eq ""} {
    add_files -norecurse -fileset sources_1 [file join $script_dir cam_ddr.v]
    puts "added: cam_ddr.v"
}

# 廃止した BRAM 経路のソース (fb_reader / vga_mono / vga_top_tb) をプロジェクトから外す
foreach f {fb_reader.v vga_mono.v vga_top_tb.v} {
    set fo [get_files -quiet */$f]
    if {$fo ne ""} {
        remove_files $fo
        puts "removed: $f"
    }
}

open_bd_design [get_files fb_test.bd]
current_bd_design fb_test

set need_cam [expr {[get_bd_intf_ports -quiet S_AXI_CFG] eq ""}]
set need_de  [expr {[get_bd_ports -quiet ACTIVE_VIDEO] eq ""}]
if {!$need_cam && !$need_de} {
    puts "cam_ddr_bd.tcl: 既に変更済みのため何もしません"
    return
}

if {$need_cam} {

# -----------------------------------------------------------------------------
# 1. クロック / リセットを外部へ出す
# -----------------------------------------------------------------------------
create_bd_port -dir O -type clk SYSCLK
connect_bd_net [get_bd_pins clk_wiz_0/sysclk] [get_bd_ports SYSCLK]

create_bd_port -dir O -type rst SYSRST_N
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports SYSRST_N]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_ports SYSRST_N]

# -----------------------------------------------------------------------------
# 2. AXI4-Lite スレーブポート (RTL の設定ステートマシン → VDMA / TPG)
# -----------------------------------------------------------------------------
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_CFG
set_property -dict [list \
    CONFIG.PROTOCOL        {AXI4LITE} \
    CONFIG.ADDR_WIDTH      {32} \
    CONFIG.DATA_WIDTH      {32} \
\
    CONFIG.HAS_WSTRB       {1} \
    CONFIG.HAS_BRESP       {1} \
    CONFIG.HAS_RRESP       {1} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.FREQ_HZ         {100000000} \
] [get_bd_intf_ports S_AXI_CFG]

set_property CONFIG.NUM_SI {3} [get_bd_cells smartconnect_0]
connect_bd_intf_net [get_bd_intf_ports S_AXI_CFG] [get_bd_intf_pins smartconnect_0/S02_AXI]

# -----------------------------------------------------------------------------
# 3. TPG 出力を外へ出し、VDMA S2MM 入力を外から受ける
# -----------------------------------------------------------------------------
delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins v_tpg_0/m_axis_video]]

create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_TPG
connect_bd_intf_net [get_bd_intf_pins v_tpg_0/m_axis_video] [get_bd_intf_ports M_AXIS_TPG]

create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_VID
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {3} \
    CONFIG.TUSER_WIDTH     {1} \
    CONFIG.HAS_TLAST       {1} \
    CONFIG.HAS_TREADY      {1} \
\
    CONFIG.HAS_TSTRB       {0} \
    CONFIG.TID_WIDTH       {0} \
    CONFIG.TDEST_WIDTH     {0} \
    CONFIG.FREQ_HZ         {100000000} \
] [get_bd_intf_ports S_AXIS_VID]
connect_bd_intf_net [get_bd_intf_ports S_AXIS_VID] [get_bd_intf_pins axi_vdma_0/S_AXIS_S2MM]

# 3 つのインターフェースは SYSCLK / SYSRST_N に同期
set_property -dict [list \
    CONFIG.ASSOCIATED_BUSIF {S_AXI_CFG:M_AXIS_TPG:S_AXIS_VID} \
    CONFIG.ASSOCIATED_RESET {SYSRST_N} \
] [get_bd_ports SYSCLK]

# -----------------------------------------------------------------------------
# 4. アドレス割り当て (S_AXI_CFG の空間)
# -----------------------------------------------------------------------------
assign_bd_address -offset 0x44A00000 -range 64K -target_address_space [get_bd_addr_spaces S_AXI_CFG] \
    [get_bd_addr_segs axi_vdma_0/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0x44A10000 -range 64K -target_address_space [get_bd_addr_spaces S_AXI_CFG] \
    [get_bd_addr_segs v_tpg_0/s_axi_CTRL/Reg] -force
}

# -----------------------------------------------------------------------------
# 4b. 有効映像期間 (vid_active_video) を外へ出す
#     VGA モニタはブランキング中 (バックポーチ) の RGB を黒レベルとして取り込むので、
#     vga_top で有効映像期間以外の RGB を 0 にするために使う (BD pclk ドメイン, RGB と同位相)
# -----------------------------------------------------------------------------
if {$need_de} {
    create_bd_port -dir O ACTIVE_VIDEO
    connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_active_video] [get_bd_ports ACTIVE_VIDEO]
}

# -----------------------------------------------------------------------------
# 5. 検証・保存・出力生成
# -----------------------------------------------------------------------------
validate_bd_design
save_bd_design
generate_target all [get_files fb_test.bd]
puts "=== cam_ddr_bd.tcl 完了: 合成から実行してください ==="
