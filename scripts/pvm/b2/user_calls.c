/* B2.3 probe: a C program with REAL function calls (every call/ret in PVM is a dynamic jump
 * through the jump table, which binfmt_pvm now appends to the kernel's), plus .rodata/.data/
 * .bss. Expected output: "B2.3 calls: fib(10)=55 cnt=8\n" */
typedef unsigned long ulong;

extern const char u_sc_md[];		/* the ecalli metadata record (start_user.S) */

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

static const char banner[] = "B2.3 calls: fib(10)=";	/* .rodata */
static int counter = 5;					/* .data  */
static char buf[32];					/* .bss   */

__attribute__((noinline)) static int fib(int n)
{
	return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

__attribute__((noinline)) static void bump(void)
{
	counter++;
}

__attribute__((noinline)) static int utoa(char *dst, unsigned v)
{
	char tmp[12];
	int n = 0, i;

	do {
		tmp[n++] = '0' + v % 10;
		v /= 10;
	} while (v);
	for (i = 0; i < n; i++)
		dst[i] = tmp[n - 1 - i];
	return n;
}

__attribute__((noinline)) static void write_all(const char *s, int len)
{
	while (len > 0) {
		long r = sys3(64, 1, (long)s, len);	/* write(1, s, len) */
		if (r <= 0)
			return;
		s += r;
		len -= r;
	}
}

int main(void)
{
	int n = 0;

	bump(); bump(); bump();				/* .data: 5 -> 8 */
	write_all(banner, sizeof(banner) - 1);
	n  = utoa(buf, fib(10));			/* 55 */
	buf[n++] = ' '; buf[n++] = 'c'; buf[n++] = 'n'; buf[n++] = 't'; buf[n++] = '=';
	n += utoa(buf + n, counter);
	buf[n++] = '\n';
	write_all(buf, n);
	return 0;
}
