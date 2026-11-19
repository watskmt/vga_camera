# =============================================================================
# create_ila.tcl  -  ILA IP 生成スクリプト (Vivado Tcl Console で実行)
# =============================================================================
# BASIC ライセンスの制限 (ILA 1 個 / 5 プローブ以内) に合わせ、ila_cam 1 個のみ使う。
#   - ila_vga がプロジェクトにあれば外す
#   - ila_cam が既にあれば作り直さず設定だけ更新する
#     (create_ip を繰り返すと ila_cam_1, _2 ... と番号付きフォルダが増えるため)
#
# 使用方法:
#   source {D:/xlinix/vga_camera/create_ila.tcl}   (何度実行してもよい)
#
# プローブ割り当ては vga_top.v の u_ila_cam のコメントを参照。
# =============================================================================

# ── ila_vga をプロジェクトから外す ────────────────────────────────────────
if {[get_ips -quiet ila_vga] ne ""} {
    export_ip_user_files -of_objects [get_ips ila_vga] -no_script -reset -force -quiet
    remove_files -quiet [get_files -quiet -of_objects [get_ips ila_vga]]
    remove_files -quiet [get_files -quiet "*ila_vga.xci"]
    puts "removed IP: ila_vga"
}

# ── ila_cam (無ければ作成) ────────────────────────────────────────────────
if {[get_ips -quiet ila_cam] eq ""} {
    create_ip \
        -name ila \
        -vendor xilinx.com \
        -library ip \
        -version 6.2 \
        -module_name ila_cam
    puts "created IP: ila_cam"
} else {
    puts "reusing IP: ila_cam ([get_files -of_objects [get_ips ila_cam] *.xci])"
}

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES  {5}    \
    CONFIG.C_DATA_DEPTH     {1024} \
    CONFIG.C_TRIGIN_EN      {false} \
    CONFIG.C_TRIGOUT_EN     {false} \
    CONFIG.C_ADV_TRIGGER    {false} \
    CONFIG.C_PROBE0_WIDTH   {8}    \
    CONFIG.C_PROBE1_WIDTH   {4}    \
    CONFIG.C_PROBE2_WIDTH   {17}   \
    CONFIG.C_PROBE3_WIDTH   {8}   \
    CONFIG.C_PROBE4_WIDTH   {12}   \
] [get_ips ila_cam]

generate_target all [get_ips ila_cam]
export_ip_user_files -of_objects [get_ips ila_cam] -no_script -sync -force -quiet
puts "ila_cam generated (5 probes)."

puts "=== ILA IP 生成完了 ==="
puts "次のステップ: Synthesis → Implementation → Generate Bitstream を実行"
