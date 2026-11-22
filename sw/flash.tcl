# =============================================================================
# flash.tcl: write bitstream + bootloader + firmware to the QSPI flash (stage 5)
#
#   Run (PowerShell, repository root, after the bitstream and the firmware are built):
#     C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -source sw\flash.tcl
#     (add  -tclargs noprog  to only create firmware/flash.mcs)
#   * Close Hardware Manager in the Vivado GUI first
#
#   Steps
#     1. Build the BRAM bootloader (sw/boot) → firmware/boot/boot.elf
#     2. Embed it in the bitstream (updatemem, BRAM of microblaze_riscv_0) → firmware/boot.bit
#     3. Firmware image: header + LOAD segment of vga_web.elf → firmware/fw_img.bin
#     4. firmware/flash.mcs: boot.bit at 0x000000, fw_img.bin at 0x800000 (MT25QL128, 16 MB)
#     5. Program the flash (erase only what the file uses), then reconfigure the FPGA
#        from the flash (= same as power-on)
#
#   Inputs: vga_camera.runs/impl_1/vga_top.bit, firmware/vga_web/build/vga_web.elf
#   (firmware/vga_top.mmi is written from impl_1 when missing or older than the bitstream)
# =============================================================================
set root  [file dirname [file dirname [file normalize [info script]]]]
set fw    $root/firmware
set bit   $root/vga_camera.runs/impl_1/vga_top.bit
set mmi   $fw/vga_top.mmi
set elf   $fw/vga_web/build/vga_web.elf
set proc_ fb_test_i/microblaze_riscv_0
set gcc   C:/AMDDesignTools/2026.1/Vitis/gnu/riscv/nt/bin/riscv64-unknown-elf-gcc.exe
set updatemem C:/AMDDesignTools/2026.1/Vivado/bin/updatemem.bat
set flash_part mt25ql128-spi-x1_x2_x4
set fw_offset  0x800000
set img_magic  0x57474156
set program [expr {[lsearch $argv noprog] < 0}]

foreach f [list $bit $elf] {
    if {![file exists $f]} { error "not found: $f" }
}
file mkdir $fw/boot

# ── 0. BRAM location info (.mmi) of the implemented design ──
if {![file exists $mmi] || [file mtime $mmi] < [file mtime $bit]} {
    open_project $root/vga_camera.xpr
    open_run impl_1
    write_mem_info -force $mmi
    close_project
}
puts "mmi : $mmi"

# ── 1. bootloader ──
set boot_elf $fw/boot/boot.elf
exec -ignorestderr $gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -Os -ffreestanding -nostdlib -nostartfiles \
    -Wall -Wl,--no-warn-rwx-segments -Wl,--build-id=none -T $root/sw/boot/boot.ld -o $boot_elf \
    $root/sw/boot/start.S $root/sw/boot/boot.c
puts "boot: $boot_elf ([file size $boot_elf] bytes ELF)"

# ── 2. bitstream with the bootloader in BRAM ──
set boot_bit $fw/boot.bit
set cwd [pwd]; cd $fw/boot   ;# updatemem leaves .jou / .log files in the current directory
exec -ignorestderr $updatemem -force -meminfo $mmi -data $boot_elf -bit $bit -proc $proc_ -out $boot_bit
cd $cwd
puts "bit : $boot_bit"

# ── 3. firmware image (ELF LOAD segment + header) ──
proc u32 {data off} {
    binary scan $data @${off}iu v
    return $v
}
set fh [open $elf rb]; set e [read $fh]; close $fh
if {[string range $e 0 3] ne "\x7fELF"} { error "$elf: not an ELF file" }
set entry [u32 $e 24]
set phoff [u32 $e 28]
binary scan $e @42su@44su phentsize phnum
set loads {}
for {set i 0} {$i < $phnum} {incr i} {
    set p [expr {$phoff + $i * $phentsize}]
    if {[u32 $e $p] == 1 && [u32 $e [expr {$p + 16}]] > 0} {
        lappend loads [list [u32 $e [expr {$p + 12}]] [u32 $e [expr {$p + 4}]] [u32 $e [expr {$p + 16}]]]
    }
}
if {[llength $loads] != 1} { error "$elf: expected 1 LOAD segment with data, found [llength $loads]" }
lassign [lindex $loads 0] load_addr off filesz
set data [string range $e $off [expr {$off + $filesz - 1}]]
while {[string length $data] % 4} { append data "\x00" }
set size [string length $data]
binary scan $data iu* words
set sum 0
foreach w $words { set sum [expr {($sum + $w) & 0xFFFFFFFF}] }
set hdr_sum [expr {~($img_magic + $load_addr + $size + $entry + $sum) & 0xFFFFFFFF}]
set img $fw/fw_img.bin
set fh [open $img wb]
puts -nonewline $fh [binary format i8 [list $img_magic $load_addr $size $entry $sum $hdr_sum 0 0]]
puts -nonewline $fh $data
close $fh
puts [format "fw  : %s (load 0x%08X, %d bytes, entry 0x%08X, sum 0x%08X)" $img $load_addr $size $entry $sum]

# ── 4. flash image ──
set mcs $fw/flash.mcs
write_cfgmem -force -format mcs -size 16 -interface SPIx4 \
    -loadbit  "up 0x0 $boot_bit" \
    -loaddata "up $fw_offset $img" \
    -file $mcs
puts "mcs : $mcs"

if {!$program} { return }

# ── 5. program the flash, then boot from it ──
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts $flash_part] 0]
set m [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.FILES                  [list $mcs] $m
set_property PROGRAM.ADDRESS_RANGE          {use_file} $m
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $m
set_property PROGRAM.BLANK_CHECK 0 $m
set_property PROGRAM.ERASE       1 $m
set_property PROGRAM.CFG_PROGRAM 1 $m
set_property PROGRAM.VERIFY      1 $m
set_property PROGRAM.CHECKSUM    0 $m
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
program_hw_cfgmem -hw_cfgmem $m
puts "flash programmed and verified"
boot_hw_device $dev
puts "FPGA reconfigured from flash"
close_hw_target
disconnect_hw_server
close_hw_manager
