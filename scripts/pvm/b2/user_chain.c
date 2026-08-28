/* B2.4 probe: exec chaining. /init prints a line, then execve("/prog2") -- a second data+JT
 * program (user_calls) that replaces it in the same thread group, so binfmt_pvm must let the
 * owner of the data window / JT range exec again. Expected UART:
 *   "B2.4 chain -> \n" followed by prog2's line (user_calls: "B2.3 calls: fib(10)=55 cnt=8",
 *   user_args (B2.5): "B2.5 argv: argc=2 argv1=hello-argv env0=B25=yes") */
extern const char u_sc_md[];

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

static const char msg[] = "B2.4 chain -> \n";		/* .rodata */
static const char path[] = "/prog2";
static const char *argv[] = { "/prog2", "hello-argv", 0 };	/* .data (pointers relocated by polkatool) */
static const char *envp[] = { "B25=yes", 0 };

__attribute__((noinline)) static void write_all(const char *s, int len)
{
	while (len > 0) {
		long r = sys3(64, 1, (long)s, len);
		if (r <= 0)
			return;
		s += r;
		len -= r;
	}
}

int main(void)
{
	write_all(msg, sizeof(msg) - 1);
	sys3(221, (long)path, (long)argv, (long)envp);	/* execve -- does not return on success */
	write_all("execve failed\n", 14);
	return 1;
}
