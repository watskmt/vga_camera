/* boot.c: BRAM bootloader (stage 5: QSPI boot)
 *
 * Runs from LMB BRAM (embedded in the bitstream by sw/flash.tcl with updatemem).
 * Copies the firmware image from QSPI flash (read through the AXI Quad SPI XIP
 * window) into DDR3 and jumps to it.
 *
 * Flash layout (sw/flash.tcl):
 *   0x000000  bitstream
 *   0x800000  image header (struct img_hdr) followed by the firmware's LOAD segment
 */
#include <stdint.h>

#define REG(a)        (*(volatile uint32_t *)(a))

#define UART_BASE     0x40600000u     /* axi_uartlite_0 */
#define UART_TX       (UART_BASE + 0x04)
#define UART_STAT     (UART_BASE + 0x08)
#define UART_TX_FULL  0x08

#define XIP_BASE      0x60000000u     /* axi_quad_spi_0 XIP window = flash 0x000000 */
#define FW_OFFSET     0x00800000u
#define IMG_MAGIC     0x57474156u     /* "VAGW" read as little-endian u32 */

#define DDR_BASE      0x80000000u
#define DDR_END       0x88000000u

#define DCACHE_BYTES  32768u          /* C_DCACHE_BYTE_SIZE */
#define CACHE_LINE    32u             /* 8 words */

struct img_hdr {
	uint32_t magic;
	uint32_t load_addr;   /* where the data goes */
	uint32_t size;        /* data bytes (multiple of 4) */
	uint32_t entry;       /* jump address */
	uint32_t sum;         /* 32-bit sum of the data words */
	uint32_t hdr_sum;     /* ~(magic + load_addr + size + entry + sum) */
	uint32_t rsvd[2];
};

static void putc_(char c)
{
	while (REG(UART_STAT) & UART_TX_FULL)
		;
	REG(UART_TX) = (uint8_t)c;
}

static void puts_(const char *s)
{
	while (*s) {
		if (*s == '\n')
			putc_('\r');
		putc_(*s++);
	}
}

static void puthex(uint32_t v)
{
	int i;
	puts_("0x");
	for (i = 28; i >= 0; i -= 4)
		putc_("0123456789ABCDEF"[(v >> i) & 0xF]);
}

/* Write back and invalidate every D-cache line, then invalidate the I-cache.
 * Same instruction as the BSP's riscv_flush_dcache / riscv_invalidate_icache:
 * cbo.flush with bit 31 set (by index, no address match). */
static void cache_sync(void)
{
	uint32_t i;
	for (i = 0; i < DCACHE_BYTES; i += CACHE_LINE) {
		register uint32_t t0 asm("t0") = i;
		asm volatile(".long 0x8022A00F" : : "r"(t0) : "memory");
	}
	asm volatile("fence" ::: "memory");
	asm volatile("fence.i" ::: "memory");
}

static void halt(const char *why)
{
	puts_("[boot] ");
	puts_(why);
	puts_(" - firmware not started (load it over JTAG with sw/run_fw.tcl)\n");
	for (;;)
		;
}

void boot_main(void)
{
	const volatile struct img_hdr *h = (const volatile struct img_hdr *)(XIP_BASE + FW_OFFSET);
	struct img_hdr hd;
	const volatile uint32_t *src;
	volatile uint32_t *dst;
	uint32_t i, n, sum;

	puts_("\n[boot] vga_camera QSPI bootloader\n");

	/* Right after configuration the first XIP reads return 0xFFFFFFFF: STARTUPE2
	 * ignores the first 3 USRCCLKO cycles, so the first SPI transfer is broken.
	 * Do dummy reads until the header magic reads back (or give up). */
	for (i = 0; i < 100 && h->magic != IMG_MAGIC; i++)
		(void)REG(XIP_BASE);
	if (i) {
		puts_("[boot] flash ready after ");
		puthex(i);
		puts_(" dummy reads\n");
	}

	hd.magic     = h->magic;
	hd.load_addr = h->load_addr;
	hd.size      = h->size;
	hd.entry     = h->entry;
	hd.sum       = h->sum;
	hd.hdr_sum   = h->hdr_sum;

	if (hd.magic != IMG_MAGIC) {
		puts_("[boot] no image at flash ");
		puthex(FW_OFFSET);
		puts_(" (read ");
		puthex(hd.magic);
		puts_(")\n");
		halt("no image");
	}
	if (hd.hdr_sum != ~(hd.magic + hd.load_addr + hd.size + hd.entry + hd.sum))
		halt("bad header checksum");
	if (hd.load_addr < DDR_BASE || hd.size == 0 || (hd.size & 3) ||
	    hd.load_addr + hd.size > DDR_END ||
	    hd.entry < hd.load_addr || hd.entry >= hd.load_addr + hd.size)
		halt("bad header");

	puts_("[boot] copying ");
	puthex(hd.size);
	puts_(" bytes to ");
	puthex(hd.load_addr);
	puts_("\n");

	src = (const volatile uint32_t *)(XIP_BASE + FW_OFFSET + sizeof(struct img_hdr));
	dst = (volatile uint32_t *)hd.load_addr;
	n = hd.size / 4;
	sum = 0;
	for (i = 0; i < n; i++) {
		uint32_t w = src[i];
		dst[i] = w;
		sum += w;
	}
	if (sum != hd.sum) {
		puts_("[boot] checksum ");
		puthex(sum);
		puts_(" != ");
		puthex(hd.sum);
		puts_("\n");
		halt("bad data checksum");
	}

	cache_sync();
	puts_("[boot] jump to ");
	puthex(hd.entry);
	puts_("\n");
	((void (*)(void))hd.entry)();
	halt("firmware returned");
}
