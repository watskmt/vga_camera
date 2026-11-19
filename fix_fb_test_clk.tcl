# =============================================================================
# fix_fb_test_clk.tcl
#   fb_test BD の clk_wiz_0 を「入力バッファ無し」に変更する。
#   vga_top では fb_test の CLK に MMCM 出力 (BUFG 後の clk100) を入れるため、
#   clk_wiz が自前で IBUF を挿入すると配置配線でエラーになる。
#
# 使い方 (Vivado Tcl Console, プロジェクトを開いた状態で):
#   source {D:/xlinix/vga_camera/fix_fb_test_clk.tcl}
# =============================================================================
open_bd_design [get_files fb_test.bd]

set_property CONFIG.PRIM_SOURCE {Global_buffer} [get_bd_cells clk_wiz_0]
puts "clk_wiz_0 PRIM_SOURCE = [get_property CONFIG.PRIM_SOURCE [get_bd_cells clk_wiz_0]]"

save_bd_design
# BD 内部の配線が完成したら以下で検証・ラッパー再生成
# validate_bd_design
# generate_target all [get_files fb_test.bd]
