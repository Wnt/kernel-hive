#include <u.h>
#include <libc.h>

/*
 * warpd - in-guest absolute-pointer agent for 9front / Plan 9.
 *
 * Speaks the streamhost daemon's newline-ASCII M/Q/P/R/B protocol and injects
 * events into the kernel mouse via /dev/mousein using the "A x y buttons msec"
 * absolute form (devmouse.c: buf[0]=='A' -> absmousetrack, true full-screen).
 *
 * Protocol (coords are guest pixels):
 *   M x y      move to (x,y), keep current buttons
 *   Q x y      probe move; replies K on a successful mouse-device write
 *   P n x y    move to (x,y) then PRESS button n   (down)
 *   R n x y    move to (x,y) then RELEASE button n (up)
 *   B n x y    move to (x,y) then click button n   (press+release; wheel 4/5)
 * Button map: plan9 bitmask = 1<<(n-1) -> 1=L 2=M 4=R 8=wheelup 16=wheeldn.
 *
 * Transport: TCP. announce/listen/accept on tcp!*!7777 (reached from the host
 * over a QEMU hostfwd). Each accepted connection runs in a child process, so
 * a persistent streamhost client and independent proof clients can coexist.
 * /dev/mousein is reopened for each command so loadvm is safe.
 *
 * Latest-wins move coalescing (mirrors win9x/warpnet.c serve() and
 * win311/agent.c flush_move()): a sustained pen-hover chain queues dozens of
 * 'M' moves in one read() chunk. Because emit() reopens /dev/mousein per event,
 * replaying every stale move makes the guest fall behind and the cursor
 * rubber-band ever farther. Instead we hold only the NEWEST pending 'M'
 * (havepend/pendx/pendy) and defer it: any non-move verb (Q/P/R/B) flushes the
 * pending move FIRST so button/probe ordering and position stay correct, and
 * each read() chunk flushes once when it is fully drained. Net: a chunk of N
 * moves snaps once to the final point (guest apply capped to ~1 move/cycle)
 * while presses/releases/wheel still fire in order at the right spot.
 */

ulong
now(void)
{
	return (ulong)(nsec()/1000000LL);
}

int
emit(int x, int y, int b)
{
	char buf[64];
	char *path[] = {"/mnt/term/dev/mousein", "/dev/mousein"};
	int i, mfd, n, wrote;

	/*
	 * Reopen for every event: a savevm/loadvm cannot retain a usable mousein
	 * fd. Try both the terminal-native device and its conventional /dev bind;
	 * after restore either namespace path may be the one rio still consumes.
	 */
	n = snprint(buf, sizeof buf, "A %d %d %d %lud", x, y, b, now());
	wrote = 0;
	for(i = 0; i < nelem(path); i++){
		mfd = open(path[i], OWRITE);
		if(mfd < 0)
			continue;
		if(write(mfd, buf, n) == n)
			wrote = 1;
		close(mfd);
	}
	return wrote;
}

int
btnmask(int n)
{
	if(n < 1 || n > 5)
		return 0;
	return 1 << (n-1);
}

void
serve(int fd)
{
	char buf[1024], line[256];
	char *f[8];
	int n, i, nline, nf, curb, ok;
	int havepend, pendx, pendy;

	nline = 0;
	curb = 0;
	havepend = 0;
	pendx = 0;
	pendy = 0;
	while((n = read(fd, buf, sizeof buf)) > 0){
		for(i = 0; i < n; i++){
			char c = buf[i];
			if(c == '\n' || c == '\r'){
				if(nline == 0)
					continue;
				line[nline] = 0;
				nline = 0;
				nf = tokenize(line, f, nelem(f));
				if(nf < 1)
					continue;
				/*
				 * Coalesce moves latest-wins: pend only the newest
				 * 'M' and apply it later, so a burst of queued moves
				 * cannot rubber-band the cursor through stale points.
				 */
				if(f[0][0] == 'M'){
					if(nf >= 3){
						pendx = atoi(f[1]);
						pendy = atoi(f[2]);
						havepend = 1;
					}
					continue;
				}
				/*
				 * Any non-move verb: flush the newest pending move
				 * FIRST so button/probe ordering and position stay
				 * correct, then handle the verb itself.
				 */
				if(havepend){
					emit(pendx, pendy, curb);
					havepend = 0;
				}
				switch(f[0][0]){
				case 'Q':
					if(nf >= 3){
						ok = emit(atoi(f[1]), atoi(f[2]), curb);
						fprint(fd, ok ? "K\n" : "E\n");
					}
					break;
				case 'P':
					if(nf >= 4){
						curb |= btnmask(atoi(f[1]));
						emit(atoi(f[2]), atoi(f[3]), curb);
					}
					break;
				case 'R':
					if(nf >= 4){
						curb &= ~btnmask(atoi(f[1]));
						emit(atoi(f[2]), atoi(f[3]), curb);
					}
					break;
				case 'B':
					if(nf >= 4){
						int bn = atoi(f[1]);
						int x = atoi(f[2]), y = atoi(f[3]);
						emit(x, y, curb | btnmask(bn));
						emit(x, y, curb);
					}
					break;
				}
			}else if(nline < sizeof line - 1){
				line[nline++] = c;
			}
		}
		/*
		 * End of this read() chunk: apply the final coalesced move once,
		 * so guest apply is capped to ~1 move/cycle and the cursor snaps
		 * straight to the latest position instead of trailing behind.
		 */
		if(havepend){
			emit(pendx, pendy, curb);
			havepend = 0;
		}
	}
}

void
main(int argc, char **argv)
{
	char *addr, adir[40], ldir[40];
	int acfd, lcfd, dfd;

	addr = "tcp!*!7777";
	if(argc > 1)
		addr = argv[1];

	acfd = announce(addr, adir);
	if(acfd < 0)
		sysfatal("announce %s: %r", addr);
	fprint(2, "warpd: listening %s, reopening /dev/mousein per event\n", addr);

	for(;;){
		lcfd = listen(adir, ldir);
		if(lcfd < 0)
			sysfatal("listen: %r");
		dfd = accept(lcfd, ldir);
		if(dfd >= 0 && rfork(RFPROC|RFFDG|RFNOWAIT) == 0){
			close(acfd);
			close(lcfd);
			serve(dfd);
			close(dfd);
			exits(nil);
		}
		close(dfd);
		close(lcfd);
	}
}
