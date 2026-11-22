# =============================================================================
# hw_bd.tcl  -  hw-face ブランチ: 顔検出エンジン用に fb_test BD を変更する
# =============================================================================
# 顔検出のハードウェア処理を試すための構成。リソースを空けるため、ほかの条件は緩める:
#
#   - v_tpg_0 (テストパターン) を削除。ポート M_AXIS_TPG も削除 (vga_top では 0 固定)
#   - MicroBlaze-V のキャッシュを各 8 KB / ライン 4 ワードに戻す (BRAM を空ける)
#   - TPG が使っていた smartconnect_0 の出力に外部ポート M_AXI_HAAR (AXI4-Lite) をつなぐ
#     → vga_top の rtl_haar/haar_engine.v。MicroBlaze-V から 0x44A3_0000 (64 KB)
#   - ILA は vga_top 側で外す (`USE_ILA 未定義)、dbg_hub の制約もコメントアウト済み
#
# 使い方 (Vivado Tcl Console, プロジェクトを開いた状態で。cam_ddr_bd / eth_bd / qspi_bd の後):
#   source {D:/xlinix/vga_camera/hw_bd.tcl}
#   何度実行してもよい (変更済みなら何もしない)。RTL / ROM ファイルもプロジェクトに追加する
# =============================================================================

set root [file dirname [file normalize [info script]]]
open_bd_design [get_files fb_test.bd]
current_bd_design fb_test
set changed 0

# ── 1. MicroBlaze-V のキャッシュ: 各 8 KB / ライン 4 ワード ──
set mb [get_bd_cells microblaze_riscv_0]
if {[get_property CONFIG.C_DCACHE_BYTE_SIZE $mb] != 8192 || [get_property CONFIG.C_ICACHE_BYTE_SIZE $mb] != 8192} {
    set_property -dict [list CONFIG.C_ICACHE_BYTE_SIZE 8192 CONFIG.C_ICACHE_LINE_LEN 4 \
                             CONFIG.C_DCACHE_BYTE_SIZE 8192 CONFIG.C_DCACHE_LINE_LEN 4] $mb
    puts "hw_bd.tcl: MicroBlaze-V のキャッシュを各 8 KB / ライン 4 ワードにしました"
    set changed 1
}

# ── 2. v_tpg_0 を削除し、その AXI-Lite の口を M_AXI_HAAR に使う ──
if {[get_bd_cells -quiet v_tpg_0] ne ""} {
    set sc_pin [get_bd_intf_pins -of_objects [get_bd_intf_nets -of_objects [get_bd_intf_pins v_tpg_0/s_axi_CTRL]] \
                -filter {MODE == Master}]
    puts "hw_bd.tcl: v_tpg_0/s_axi_CTRL <- $sc_pin"
    delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins v_tpg_0/s_axi_CTRL]]
    delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins v_tpg_0/m_axis_video]]
    delete_bd_objs [get_bd_cells v_tpg_0]
    if {[get_bd_intf_ports -quiet M_AXIS_TPG] ne ""} {
        delete_bd_objs [get_bd_intf_ports M_AXIS_TPG]
    }

    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_HAAR
    set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 32 \
                             CONFIG.FREQ_HZ [get_property CONFIG.FREQ_HZ [get_bd_ports SYSCLK]]] \
        [get_bd_intf_ports M_AXI_HAAR]
    connect_bd_intf_net $sc_pin [get_bd_intf_ports M_AXI_HAAR]

    # SYSCLK に関連付けるバス: M_AXIS_TPG を外して M_AXI_HAAR を加える
    set bus [split [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_ports SYSCLK]] :]
    set bus [lsearch -all -inline -not -exact $bus M_AXIS_TPG]
    lappend bus M_AXI_HAAR
    set_property CONFIG.ASSOCIATED_BUSIF [join $bus :] [get_bd_ports SYSCLK]

    set mb_d [get_bd_addr_spaces microblaze_riscv_0/Data]
    assign_bd_address -offset 0x44A30000 -range 64K -target_address_space $mb_d \
        [get_bd_addr_segs M_AXI_HAAR/Reg] -force
    foreach sp [list [get_bd_addr_spaces -quiet S_AXI_CFG] [get_bd_addr_spaces -quiet axi_vip_0/Master_AXI]] {
        if {$sp eq ""} { continue }
        catch { exclude_bd_addr_seg -target_address_space $sp [get_bd_addr_segs M_AXI_HAAR/Reg] }
    }
    puts "hw_bd.tcl: v_tpg_0 を削除し、M_AXI_HAAR (0x44A3_0000) を追加しました"
    set changed 1
}

if {$changed} {
    validate_bd_design
    save_bd_design
    generate_target all [get_files fb_test.bd]
} else {
    puts "hw_bd.tcl: BD は変更済み"
}

# ── 3. エンジンの RTL / ROM ファイルをプロジェクトに追加 ──
foreach f {haar_engine.v haar_params.vh haar_weak.mem haar_stage.mem} {
    set p $root/rtl_haar/$f
    if {[get_files -quiet $p] eq ""} {
        add_files -norecurse -fileset sources_1 $p
        puts "hw_bd.tcl: added $p"
    }
}
set_property file_type {Verilog Header} [get_files $root/rtl_haar/haar_params.vh]
set_property file_type {Memory Initialization Files} [get_files $root/rtl_haar/haar_weak.mem]
set_property file_type {Memory Initialization Files} [get_files $root/rtl_haar/haar_stage.mem]
puts "=== hw_bd.tcl 完了 ==="
