/* B4 probe: the B3 vfork+execv busybox launcher, extended with (B4.1) initramfs files
 * (ls/cat), (B4.2) a console-RX line echo, and (B4.3) an INTERACTIVE hush session on
 * /dev/console. The host side feeds the console via scripts/pvm/uart_feed.sh. */
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

static void run(char *const argv[])
{
	int st = -1;
	pid_t pid = vfork();

	if (pid == 0) {
		execv("/prog2", argv);
		_exit(127);
	}
	waitpid(pid, &st, 0);
	printf("B4 launcher: %s %s -> exit %d\n", argv[0], argv[1] ? argv[1] : "", WEXITSTATUS(st));
	fflush(stdout);
}

int main(void)
{
	printf("B4 busybox launcher: start\n");
	fflush(stdout);
	run((char *const[]){"busybox", "uname", "-a", NULL});
	run((char *const[]){"busybox", "ls", "-la", "/", NULL});
	run((char *const[]){"busybox", "cat", "/etc/motd", NULL});
	/* B4.2: console RX (8250 irq-less timer polling): echo one line back */
	printf("B4 rx: type a line!\n");
	fflush(stdout);
	char buf[80];
	int n = 0;
	char c;
	while (n < 79 && read(0, &c, 1) == 1) {
		if (c == '\n' || c == '\r')
			break;
		buf[n++] = c;
	}
	buf[n] = 0;
	printf("B4 rx: got \"%s\" (%d bytes)\n", buf, n);
	fflush(stdout);
	/* B4.3: a real interactive shell (exec #4 -- needs the code-region reuse) */
	printf("B4: starting interactive hush\n");
	fflush(stdout);
	run((char *const[]){"busybox", "hush", NULL});
	/* B4.3 reuse proof: keep exec'ing -- the old kernel died on the 4th append */
	run((char *const[]){"busybox", "uname", "-m", NULL});
	run((char *const[]){"busybox", "echo", "exec 6 alive", NULL});
	run((char *const[]){"busybox", "hush", "-c", "echo exec 7 says $((40+2))", NULL});
	printf("B4 busybox launcher: done\n");
	return 0;
}
