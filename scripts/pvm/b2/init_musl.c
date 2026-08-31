/* B3.2 probe: a musl launcher that vfork+execv's busybox applets (/prog2 = the busybox
 * multiplexer, applet = argv[1]) and waits for each. Real fork-less process control. */
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
	printf("B3 launcher: %s %s -> exit %d\n", argv[0], argv[1] ? argv[1] : "", WEXITSTATUS(st));
	fflush(stdout);
}

int main(void)
{
	printf("B3 busybox launcher: start\n");
	fflush(stdout);
	run((char *const[]){"busybox", "uname", "-a", NULL});
	run((char *const[]){"busybox", "echo", "hello from busybox echo", NULL});
	run((char *const[]){"busybox", "hush", "-c", "echo shell says hi && uname -m", NULL});
	printf("B3 busybox launcher: done\n");
	return 0;
}
