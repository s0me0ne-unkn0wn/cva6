/* B2.7 probe: two data-carrying PVM processes alive at once. /init (slot 0) vforks and the
 * child execve()s /prog2 (user_args, slot 1, its own JT range); the parent stays alive through
 * the child's run, waits, and checks its own .data survived. Expected UART:
 *   "B2.7 spawn: parent start\n"
 *   "B2.5 argv: argc=2 argv1=from-spawn env0=(none)\n"     (the child, from its own slot)
 *   "B2.7 spawn: child done, data intact\n"
 * NOMMU has no fork -- vfork only: clone(CLONE_VM|CLONE_VFORK|SIGCHLD), child on the same
 * stack (writes only below the parent's live sp), execve() or _exit immediately. */
extern const char u_sc_md[];

static inline long sysc(long nr, long a, long b, long c, long d, long e)
{
	register long t0 __asm__("t0") = nr;
	register long a0 __asm__("a0") = a;
	register long a1 __asm__("a1") = b;
	register long a2 __asm__("a2") = c;
	register long a3 __asm__("a3") = d;
	register long a4 __asm__("a4") = e;
	__asm__ volatile(".insn r 0xb, 0, 0, zero, zero, zero\n\t.quad u_sc_md"
			 : "+r"(a0), "+r"(a1)
			 : "r"(t0), "r"(a2), "r"(a3), "r"(a4)
			 : "memory");
	return a0;
}

static const char msg0[] = "B2.7 spawn: parent start\n";
static const char msg1[] = "B2.7 spawn: child done, data intact\n";
static const char msg1bad[] = "B2.7 spawn: child done, DATA CLOBBERED\n";
static const char path[] = "/prog2";
static const char *cargv[] = { "/prog2", "from-spawn", 0 };
static const char *cenvp[] = { 0 };
static volatile int mark = 0x1177;			/* .data canary: must survive the child */

__attribute__((noinline)) static void write_all(const char *s, int len)
{
	while (len > 0) {
		long r = sysc(64, 1, (long)s, len, 0, 0);
		if (r <= 0)
			return;
		s += r;
		len -= r;
	}
}

#define CLONE_VFORK_FLAGS (0x100 /*CLONE_VM*/ | 0x4000 /*CLONE_VFORK*/ | 17 /*SIGCHLD*/)

int main(void)
{
	long pid;
	int status = -1;

	write_all(msg0, sizeof(msg0) - 1);
	pid = sysc(220, CLONE_VFORK_FLAGS, 0, 0, 0, 0);	/* clone: vfork */
	if (pid == 0) {
		sysc(221, (long)path, (long)cargv, (long)cenvp, 0, 0);	/* execve */
		sysc(93, 127, 0, 0, 0, 0);				/* _exit(127) if it failed */
	}
	sysc(260, -1, (long)&status, 0, 0, 0);			/* wait4(-1, &status, 0, 0) */
	if (mark == 0x1177)
		write_all(msg1, sizeof(msg1) - 1);
	else
		write_all(msg1bad, sizeof(msg1bad) - 1);
	return 0;
}
