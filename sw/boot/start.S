/* start.S: reset entry of the BRAM bootloader (MicroBlaze-V reset vector = 0x0) */
	.section .text.start, "ax"
	.globl _start
_start:
	csrw	mie, zero          /* no interrupts */
	la	sp, __stack_top
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sw	zero, 0(t0)
	addi	t0, t0, 4
	j	1b
2:	call	boot_main
3:	j	3b
