# =============================================================================
# create_ila.tcl  -  ILA IP 生成スクリプト (Vivado Tcl Console で実行)
# =============================================================================
# 使用方法 (既存 IP を削除してから実行):
#   Vivado Tcl Console で:
#     remove_files [get_files -of_objects [get_ips ila_cam] -quiet] -quiet
#     export_ip_user_files -of_objects [get_ips ila_cam] -no_script -reset -force -quiet
#     source {D:/xlinix/vga_camera/create_ila.tcl}
# =============================================================================

# ── ila_cam : カメラキャプチャ監視 (cam_pclk_g ドメイン) ──────────────────
create_ip \
    -name ila \
    -vendor xilinx.com \
    -library ip \
    -version 6.2 \
    -module_name ila_cam

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES  {10}   \
    CONFIG.C_DATA_DEPTH     {1024} \
    CONFIG.C_TRIGIN_EN      {false} \
    CONFIG.C_TRIGOUT_EN     {false} \
    CONFIG.C_ADV_TRIGGER    {false} \
    CONFIG.C_PROBE0_WIDTH   {1}    \
    CONFIG.C_PROBE1_WIDTH   {1}    \
    CONFIG.C_PROBE2_WIDTH   {8}    \
    CONFIG.C_PROBE3_WIDTH   {1}    \
    CONFIG.C_PROBE4_WIDTH   {17}   \
    CONFIG.C_PROBE5_WIDTH   {12}   \
    CONFIG.C_PROBE6_WIDTH   {2}    \
    CONFIG.C_PROBE7_WIDTH   {1}    \
    CONFIG.C_PROBE8_WIDTH   {8}    \
    CONFIG.C_PROBE9_WIDTH   {8}    \
] [get_ips ila_cam]

generate_target all [get_ips ila_cam]
puts "ila_cam generated."

# ── ila_vga : VGA 出力監視 (pclk ドメイン) ────────────────────────────────
create_ip \
    -name ila \
    -vendor xilinx.com \
    -library ip \
    -version 6.2 \
    -module_name ila_vga

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES  {6}    \
    CONFIG.C_DATA_DEPTH     {1024} \
    CONFIG.C_TRIGIN_EN      {false} \
    CONFIG.C_TRIGOUT_EN     {false} \
    CONFIG.C_ADV_TRIGGER    {false} \
    CONFIG.C_PROBE0_WIDTH   {4}    \
    CONFIG.C_PROBE1_WIDTH   {4}    \
    CONFIG.C_PROBE2_WIDTH   {4}    \
    CONFIG.C_PROBE3_WIDTH   {1}    \
    CONFIG.C_PROBE4_WIDTH   {1}    \
    CONFIG.C_PROBE5_WIDTH   {12}   \
] [get_ips ila_vga]

generate_target all [get_ips ila_vga]
puts "ila_vga generated."

puts "=== ILA IP 生成完了 ==="
puts "次のステップ: Synthesis → Implementation → Generate Bitstream を実行"
