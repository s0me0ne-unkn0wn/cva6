/* B4 hush-math micro-repro: busybox's add_till_closing_bracket computes
 *   char dbl = end_ch & 0x80; if (!dbl) ...
 * which gcc -Os lowers to `sext.b + bgez`. On silicon busybox takes the !dbl
 * path for end_ch=0xA9. Reproduce with the exact same source pattern. */
#include <stdio.h>

volatile unsigned end_ch_v = 0xA9;

int main(void)
{
	unsigned end_ch = end_ch_v;
	char dbl = end_ch & 0x80;

	if (!dbl)
		printf("B4 sextbr: BUG (!dbl taken, end_ch=%x)\n", end_ch);
	else
		printf("B4 sextbr: OK (dbl path, end_ch=%x)\n", end_ch);
	return 0;
}
