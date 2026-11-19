# =============================================================================
# fix_fb_test_bd.tcl  -  fb_test ブロックデザインの内部配線を作り直す
# =============================================================================
# 構成 (DDR3 フレームバッファ・テスト):
#
#   v_tpg_0 ──AXIS(24b)──► axi_vdma_0 S2MM ──┐   (VDMA S2MM 幅は TPG から自動伝搬)
#                                             ├─ smartconnect_1 ─► MIG ─► DDR3
#   v_axi4s_vid_out_0 ◄─AXIS(24b)── VDMA MM2S ┘
#        │  ▲ vtiming
#        │  └── v_tc_0 (640x480, pclk 25 MHz)
#        └──► RGB / HSYNC / VSYNC (外部ポート, pclk ドメイン)
#
#   microblaze_riscv_0 ─┐
#   axi_vip_0 (sim用) ──┴─ smartconnect_0 ─► v_tpg_0 CTRL / axi_vdma_0 S_AXI_LITE
#
# クロック (clk_wiz_0, 入力 CLK=100 MHz):
#   sysclk 100 MHz : MicroBlaze / AXI / TPG / VDMA / vid_out aclk
#   pclk    25 MHz : v_tc / vid_out vid_io_out_clk
#   sdclk  333 MHz : MIG sys_clk_i
#   refclk 200 MHz : MIG clk_ref_i (IDELAYCTRL)
#   MIG ui_clk     : smartconnect_1 aclk1 / MIG S_AXI
#
# 使い方 (Vivado Tcl Console, プロジェクトを開いた状態で):
#   source {D:/xlinix/vga_camera/fix_fb_test_bd.tcl}
# =============================================================================

open_bd_design [get_files fb_test.bd]
current_bd_design fb_test

# -----------------------------------------------------------------------------
# 0. 既存の配線を全削除 (外部ポートとセルは残す) / 不要ポート削除
# -----------------------------------------------------------------------------
delete_bd_objs [get_bd_intf_nets -quiet] [get_bd_nets -quiet]
delete_bd_objs [get_bd_ports -quiet {sys_clk sys_rst_n}]

# -----------------------------------------------------------------------------
# 1. IP 設定
# -----------------------------------------------------------------------------
# clk_wiz: 200 MHz の refclk を追加 (VCO 1000 MHz / 5)
set_property -dict [list \
    CONFIG.PRIM_SOURCE                {Global_buffer} \
    CONFIG.CLKOUT4_USED               {true} \
    CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.CLK_OUT4_PORT              {refclk} \
    CONFIG.NUM_OUT_CLKS               {4} \
] [get_bd_cells clk_wiz_0]

# VDMA: S2MM を有効化, ストリーム幅を TPG / vid_out に合わせ 24 bit
set_property -dict [list \
    CONFIG.c_include_s2mm             {1} \
    CONFIG.c_include_mm2s             {1} \
    CONFIG.c_num_fstores              {3} \
    CONFIG.c_m_axis_mm2s_tdata_width  {24} \
    CONFIG.c_mm2s_max_burst_length    {16} \
    CONFIG.c_s2mm_max_burst_length    {16} \
    CONFIG.c_mm2s_linebuffer_depth    {512} \
    CONFIG.c_s2mm_linebuffer_depth    {512} \
] [get_bd_cells axi_vdma_0]

# vid_out: AXI 側 100 MHz / 映像側 25 MHz の非同期クロック
set_property -dict [list CONFIG.C_HAS_ASYNC_CLK {1}] [get_bd_cells v_axi4s_vid_out_0]

# SmartConnect
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {1}] [get_bd_cells smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells smartconnect_1]

# 追加のリセットブロック (MIG ui_clk 用 / pclk 用)
if {[get_bd_cells -quiet rst_ui] eq ""} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ui
}
if {[get_bd_cells -quiet rst_pix] eq ""} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pix
}

# -----------------------------------------------------------------------------
# 2. クロック
# -----------------------------------------------------------------------------
connect_bd_net [get_bd_ports CLK] [get_bd_pins clk_wiz_0/clk_in1]

connect_bd_net [get_bd_pins clk_wiz_0/sysclk] \
    [get_bd_pins microblaze_riscv_0/Clk] \
    [get_bd_pins smartconnect_0/aclk] \
    [get_bd_pins smartconnect_1/aclk] \
    [get_bd_pins axi_vip_0/aclk] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
    [get_bd_pins v_tpg_0/ap_clk] \
    [get_bd_pins axi_vdma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_vdma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_vdma_0/m_axis_mm2s_aclk] \
    [get_bd_pins axi_vdma_0/m_axi_s2mm_aclk] \
    [get_bd_pins axi_vdma_0/s_axis_s2mm_aclk] \
    [get_bd_pins v_axi4s_vid_out_0/aclk]

connect_bd_net [get_bd_pins clk_wiz_0/pclk] \
    [get_bd_pins v_tc_0/clk] \
    [get_bd_pins v_axi4s_vid_out_0/vid_io_out_clk] \
    [get_bd_pins rst_pix/slowest_sync_clk]

connect_bd_net [get_bd_pins clk_wiz_0/sdclk]  [get_bd_pins fb_test_mig_7series_1_0/sys_clk_i]
connect_bd_net [get_bd_pins clk_wiz_0/refclk] [get_bd_pins fb_test_mig_7series_1_0/clk_ref_i]

connect_bd_net [get_bd_pins fb_test_mig_7series_1_0/ui_clk] \
    [get_bd_pins smartconnect_1/aclk1] \
    [get_bd_pins rst_ui/slowest_sync_clk]

# -----------------------------------------------------------------------------
# 3. リセット
# -----------------------------------------------------------------------------
connect_bd_net [get_bd_ports RESET] \
    [get_bd_pins clk_wiz_0/reset] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in] \
    [get_bd_pins rst_pix/ext_reset_in]

connect_bd_net [get_bd_pins clk_wiz_0/locked] \
    [get_bd_pins proc_sys_reset_0/dcm_locked] \
    [get_bd_pins rst_pix/dcm_locked]

# MIG sys_rst (ACTIVE HIGH): clk_wiz ロック後に解除
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_reset] \
    [get_bd_pins fb_test_mig_7series_1_0/sys_rst]

connect_bd_net [get_bd_pins proc_sys_reset_0/mb_reset] [get_bd_pins microblaze_riscv_0/Reset]

connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
    [get_bd_pins smartconnect_0/aresetn] \
    [get_bd_pins smartconnect_1/aresetn]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_vip_0/aresetn] \
    [get_bd_pins v_tpg_0/ap_rst_n] \
    [get_bd_pins axi_vdma_0/axi_resetn] \
    [get_bd_pins v_axi4s_vid_out_0/aresetn]

# MIG ui_clk ドメイン
connect_bd_net [get_bd_pins fb_test_mig_7series_1_0/ui_clk_sync_rst] [get_bd_pins rst_ui/ext_reset_in]
connect_bd_net [get_bd_pins fb_test_mig_7series_1_0/mmcm_locked]     [get_bd_pins rst_ui/dcm_locked]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] [get_bd_pins fb_test_mig_7series_1_0/aresetn]

# pclk ドメイン
connect_bd_net [get_bd_pins rst_pix/peripheral_aresetn] [get_bd_pins v_tc_0/resetn]
connect_bd_net [get_bd_pins rst_pix/peripheral_reset]   [get_bd_pins v_axi4s_vid_out_0/vid_io_out_reset]

# -----------------------------------------------------------------------------
# 4. AXI-MM
# -----------------------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins axi_vip_0/M_AXI]            [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins microblaze_riscv_0/M_AXI_DP] [get_bd_intf_pins smartconnect_0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI]     [get_bd_intf_pins v_tpg_0/s_axi_CTRL]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M01_AXI]     [get_bd_intf_pins axi_vdma_0/S_AXI_LITE]

connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_MM2S]      [get_bd_intf_pins smartconnect_1/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_S2MM]      [get_bd_intf_pins smartconnect_1/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_1/M00_AXI]     [get_bd_intf_pins fb_test_mig_7series_1_0/S_AXI]

connect_bd_intf_net [get_bd_intf_pins fb_test_mig_7series_1_0/DDR3] [get_bd_intf_ports ddr3]
connect_bd_net [get_bd_pins fb_test_mig_7series_1_0/init_calib_complete] [get_bd_ports init_calib_complete]

# -----------------------------------------------------------------------------
# 5. 映像ストリーム / タイミング
# -----------------------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins v_tpg_0/m_axis_video]   [get_bd_intf_pins axi_vdma_0/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins v_axi4s_vid_out_0/video_in]

# v_tc → vid_out (HSYNC_1/VSYNC_1 外部ポートへも分岐するため個別ネットで接続)
connect_bd_net [get_bd_pins v_tc_0/hsync_out]        [get_bd_pins v_axi4s_vid_out_0/vtg_hsync] [get_bd_ports HSYNC_1]
connect_bd_net [get_bd_pins v_tc_0/vsync_out]        [get_bd_pins v_axi4s_vid_out_0/vtg_vsync] [get_bd_ports VSYNC_1]
connect_bd_net [get_bd_pins v_tc_0/hblank_out]       [get_bd_pins v_axi4s_vid_out_0/vtg_hblank]
connect_bd_net [get_bd_pins v_tc_0/vblank_out]       [get_bd_pins v_axi4s_vid_out_0/vtg_vblank]
connect_bd_net [get_bd_pins v_tc_0/active_video_out] [get_bd_pins v_axi4s_vid_out_0/vtg_active_video]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vtg_ce]        [get_bd_pins v_tc_0/gen_clken]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/sof_state_out] [get_bd_pins v_tc_0/sof_state]

connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_data]  [get_bd_ports RGB]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_hsync] [get_bd_ports HSYNC]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_vsync] [get_bd_ports VSYNC]
connect_bd_net [get_bd_pins v_axi4s_vid_out_0/status]    [get_bd_ports status]

# cam_stream: 未接続のままだとクロック未関連付けの CRITICAL WARNING になるため削除。
#   カメラを S2MM につなぐ段階で、BD 内クロックに関連付けて作り直す。
delete_bd_objs [get_bd_intf_ports -quiet cam_stream]

# -----------------------------------------------------------------------------
# 6. MicroBlaze-V ローカルメモリ (16KB) + デバッグモジュール (MDM-V)
#    BRAM は vga_top 側のフレームバッファと共有のため 16KB に抑える
# -----------------------------------------------------------------------------
set_property -dict [list CONFIG.C_I_LMB {1} CONFIG.C_D_LMB {1} CONFIG.C_DEBUG_ENABLED {1}] \
    [get_bd_cells microblaze_riscv_0]

foreach {name vlnv} {
    ilmb_v10           xilinx.com:ip:lmb_v10:3.0
    dlmb_v10           xilinx.com:ip:lmb_v10:3.0
    ilmb_bram_if_cntlr xilinx.com:ip:lmb_bram_if_cntlr:4.0
    dlmb_bram_if_cntlr xilinx.com:ip:lmb_bram_if_cntlr:4.0
    lmb_bram           xilinx.com:ip:blk_mem_gen:8.4
    mdm_0              xilinx.com:ip:mdm_riscv:1.0
} {
    if {[get_bd_cells -quiet $name] eq ""} { create_bd_cell -type ip -vlnv $vlnv $name }
}
set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} CONFIG.use_bram_block {BRAM_Controller}] \
    [get_bd_cells lmb_bram]
set_property -dict [list CONFIG.C_USE_UART {0}] [get_bd_cells mdm_0]

connect_bd_intf_net [get_bd_intf_pins microblaze_riscv_0/ILMB]      [get_bd_intf_pins ilmb_v10/LMB_M]
connect_bd_intf_net [get_bd_intf_pins microblaze_riscv_0/DLMB]      [get_bd_intf_pins dlmb_v10/LMB_M]
connect_bd_intf_net [get_bd_intf_pins ilmb_v10/LMB_Sl_0]            [get_bd_intf_pins ilmb_bram_if_cntlr/SLMB]
connect_bd_intf_net [get_bd_intf_pins dlmb_v10/LMB_Sl_0]            [get_bd_intf_pins dlmb_bram_if_cntlr/SLMB]
connect_bd_intf_net [get_bd_intf_pins ilmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins dlmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTB]
connect_bd_intf_net [get_bd_intf_pins mdm_0/MBDEBUG_0]              [get_bd_intf_pins microblaze_riscv_0/DEBUG]

connect_bd_net -net [get_bd_nets -of [get_bd_pins clk_wiz_0/sysclk]] \
    [get_bd_pins ilmb_v10/LMB_Clk] [get_bd_pins dlmb_v10/LMB_Clk] \
    [get_bd_pins ilmb_bram_if_cntlr/LMB_Clk] [get_bd_pins dlmb_bram_if_cntlr/LMB_Clk]
connect_bd_net [get_bd_pins proc_sys_reset_0/bus_struct_reset] \
    [get_bd_pins ilmb_v10/SYS_Rst] [get_bd_pins dlmb_v10/SYS_Rst] \
    [get_bd_pins ilmb_bram_if_cntlr/LMB_Rst] [get_bd_pins dlmb_bram_if_cntlr/LMB_Rst]
connect_bd_net [get_bd_pins mdm_0/Debug_SYS_Rst] [get_bd_pins proc_sys_reset_0/mb_debug_sys_rst]

# -----------------------------------------------------------------------------
# 7. アドレス割り当て
#    MicroBlaze : LMB 0x0000_0000 (16K) / VDMA 0x44A0_0000 / TPG 0x44A1_0000
#    axi_vip    : VDMA 0x44A0_0000 / TPG 0x44A1_0000 (fb_test_tb.sv の TPG_BASE と一致)
#    VDMA       : DDR3 0x8000_0000 (128M)
# -----------------------------------------------------------------------------
# 既存の TPG 割り当て (0x0) は LMB と衝突するので外し、両マスタとも 0x44A1_0000 に揃える
foreach sp {microblaze_riscv_0/Data axi_vip_0/Master_AXI} {
    foreach s [get_bd_addr_segs -quiet -of [get_bd_addr_spaces $sp]] {
        if {[string match *v_tpg_0* $s]} { delete_bd_objs $s }
    }
}
assign_bd_address -target_address_space /axi_vip_0/Master_AXI -offset 0x44A10000 -range 64K \
    [get_bd_addr_segs v_tpg_0/s_axi_CTRL/Reg]
assign_bd_address -target_address_space /microblaze_riscv_0/Instruction -offset 0x00000000 -range 16K \
    [get_bd_addr_segs ilmb_bram_if_cntlr/SLMB/Mem]
assign_bd_address -target_address_space /microblaze_riscv_0/Data -offset 0x00000000 -range 16K \
    [get_bd_addr_segs dlmb_bram_if_cntlr/SLMB/Mem]
assign_bd_address -target_address_space /microblaze_riscv_0/Data -offset 0x44A10000 -range 64K \
    [get_bd_addr_segs v_tpg_0/s_axi_CTRL/Reg]
assign_bd_address

# -----------------------------------------------------------------------------
# 8. 検証 / 保存
# -----------------------------------------------------------------------------
regenerate_bd_layout
validate_bd_design
save_bd_design

puts "---- address map ----"
foreach sp [get_bd_addr_spaces] {
    foreach s [get_bd_addr_segs -quiet -of $sp] {
        puts "  $sp : [get_property SLAVE $s]  offset=[get_property OFFSET $s] range=[get_property RANGE $s]"
    }
}
puts "fix_fb_test_bd.tcl: done"
