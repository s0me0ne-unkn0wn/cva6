/* B2.6 probe: the brk heap. The kernel points brk at the tail of the reserved data window
 * (behind .data/.bss, up to 0x800000); NOMMU sys_brk moves inside that range with no
 * allocation. Steps: read brk(0), grow by 8 KiB, write/read a pattern across the new
 * region, try to grow past the window (must be refused), shrink back.
 * Expected UART: "B2.6 heap: base=0x0072xxxx grow=ok rw=ok deny=ok shrink=ok\n" */
extern const char u_sc_md[];

static inline long sys1(long nr, long a)
{
	register long t0 __asm__("t0") = nr;
	register long a0 __asm__("a0") = a;
	__asm__ volatile(".insn r 0xb, 0, 0, zero, zero, zero\n\t.quad u_sc_md"
			 : "+r"(a0)
			 : "r"(t0)
			 : "a1", "memory");
	return a0;
}

static inline long sys3(long nr, long a, long b, long c)
{
	register long t0 __asm__("t0") = nr;
	register long a0 __asm__("a0") = a;
	register long a1 __asm__("a1") = b;
	register long a2 __asm__("a2") = c;
	__asm__ volatile(".insn r 0xb, 0, 0, zero, zero, zero\n\t.quad u_sc_md"
			 : "+r"(a0), "+r"(a1)
			 : "r"(t0), "r"(a2)
			 : "memory");
	return a0;
}

static char buf[96];

__attribute__((noinline)) static int put(int n, const char *s)
{
	while (*s && n < (int)sizeof(buf) - 1)
		buf[n++] = *s++;
	return n;
}

__attribute__((noinline)) static int puthex32(int n, unsigned long v)
{
	int i;

	n = put(n, "0x");
	for (i = 28; i >= 0; i -= 4)
		buf[n++] = "0123456789abcdef"[(v >> i) & 0xf];
	return n;
}

#define GROW 8192

int main(void)
{
	unsigned long b0, b1, b2, b3;
	volatile unsigned char *p;
	unsigned long i;
	int rw_ok = 1, n = 0;

	b0 = sys1(214, 0);				/* brk(0) = the window tail base */
	b1 = sys1(214, b0 + GROW);			/* grow */
	p  = (volatile unsigned char *)b0;
	for (i = 0; i < GROW; i++)
		p[i] = (unsigned char)(i * 7 + 3);
	for (i = 0; i < GROW; i++)
		if (p[i] != (unsigned char)(i * 7 + 3))
			rw_ok = 0;
	b2 = sys1(214, 0x900000);			/* past the window: must be refused */
	b3 = sys1(214, b0);				/* shrink back */

	n = put(n, "B2.6 heap: base=");
	n = puthex32(n, b0);
	n = put(n, b1 == b0 + GROW ? " grow=ok" : " grow=FAIL");
	n = put(n, rw_ok ? " rw=ok" : " rw=FAIL");
	n = put(n, b2 == b1 ? " deny=ok" : " deny=FAIL");
	n = put(n, b3 == b0 ? " shrink=ok" : " shrink=FAIL");
	buf[n++] = '\n';
	sys3(64, 1, (long)buf, n);
	return 0;
}
