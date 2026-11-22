/* boot.ld: BRAM bootloader, LMB BRAM 16 KB at 0x0 (code, data and stack) */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	lmb : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
	.text : {
		KEEP(*(.text.start))
		*(.text .text.*)
		*(.rodata .rodata.* .srodata .srodata.*)
	} > lmb
	.data : {
		*(.data .data.* .sdata .sdata.*)
	} > lmb
	.bss (NOLOAD) : {
		. = ALIGN(4);
		__bss_start = .;
		*(.bss .bss.* .sbss .sbss.* COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > lmb
	__stack_top = ORIGIN(lmb) + LENGTH(lmb);
	/DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) }
}
