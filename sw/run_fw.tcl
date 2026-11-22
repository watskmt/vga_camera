# =============================================================================
# run_fw.tcl: write the bitstream to the FPGA, load vga_web.elf over JTAG and run it (xsdb)
#
#   Run (PowerShell, repository root):
#     C:\AMDDesignTools\2026.1\Vitis\bin\xsdb.bat sw\run_fw.tcl
#   * Close Hardware Manager in Vivado first (Close Hardware Manager / Close Target)
#   * The program goes into DDR3, so it is lost at power off (boot from flash is stage 5)
# =============================================================================
set root [file dirname [file dirname [file normalize [info script]]]]
set bit  $root/vga_camera.runs/impl_1/vga_top.bit
set elf  $root/firmware/vga_web/build/vga_web.elf

foreach f [list $bit $elf] {
    if {![file exists $f]} { error "not found: $f" }
}

connect
targets -set -nocase -filter {name =~ "xc7a35t*"}
puts "FPGA: $bit"
fpga -file $bit
after 2000   ;# wait for MIG (DDR3) calibration

targets -set -nocase -filter {name =~ "*MicroBlaze V*#0*" || name =~ "*Hart*#0*"}
rst -processor
puts "ELF : $elf"
dow $elf
con
puts "running: open http://<IP>/ in a browser (IP is shown on UART 115200 bps)"
disconnect
