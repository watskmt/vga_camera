# =============================================================================
# export_xsa.tcl: write the implementation result (with bitstream) to firmware/vga_top.xsa
#
#   In the Vivado GUI Tcl Console: source {D:/xlinix/vga_camera/sw/export_xsa.tcl}
#   Batch: vivado -mode batch -source sw/export_xsa.tcl
#   (Same as File > Export > Export Hardware > Include bitstream)
# =============================================================================
set root [file dirname [file dirname [file normalize [info script]]]]
if {[catch {current_project}]} { open_project $root/vga_camera.xpr }
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "impl_1 has not reached write_bitstream"
}
file mkdir $root/firmware
open_run impl_1
write_hw_platform -fixed -include_bit -force $root/firmware/vga_top.xsa
puts "XSA: $root/firmware/vga_top.xsa"
