/* B2.5 probe: argc/argv/envp from the Linux initial stack (binfmt_pvm pvm_create_tables +
 * start_user.S). Run as /prog2 by user_chain: expected
 *   "B2.5 argv: argc=2 argv1=hello-argv env0=B25=yes\n" */
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

static char buf[128];

__attribute__((noinline)) static int put(int n, const char *s)
{
	while (*s && n < (int)sizeof(buf) - 1)
		buf[n++] = *s++;
	return n;
}

int main(int argc, char **argv)
{
	char **envp = argv + argc + 1;
	int n = 0;

	n = put(n, "B2.5 argv: argc=");
	buf[n++] = '0' + (argc % 10);
	n = put(n, " argv1=");
	n = put(n, argc > 1 ? argv[1] : "(none)");
	n = put(n, " env0=");
	n = put(n, envp[0] ? envp[0] : "(none)");
	buf[n++] = '\n';
	sys3(64, 1, (long)buf, n);
	return 0;
}
