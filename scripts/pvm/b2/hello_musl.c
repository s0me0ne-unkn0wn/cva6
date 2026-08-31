/* B3 probe: a real musl hello world (printf -> stdio -> writev/write, exit_group). */
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	printf("B3 musl: hello from printf! argc=%d argv0=%s uid=%d\n",
	       argc, argv[0], (int)getuid());
	return 0;
}
