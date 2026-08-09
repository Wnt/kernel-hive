/*
  Previous - abspointer.c

  Absolute pointer control channel (kernel-hive gallery patch).

  The NeXT mouse is a serial device on the KMS: every packet carries a SIGNED
  6-BIT RELATIVE delta, and NeXTSTEP's Mach event driver applies its own
  acceleration curve on top, so a host that knows exactly where the visitor
  pointed cannot express it. This file gives Previous a second, absolute input
  path: a line-oriented UNIX-socket control channel whose `abs X Y` places the
  NeXT cursor at an exact guest pixel by writing the event driver's own
  cursorLoc in guest RAM and then letting the driver post its normal
  zero-delta mouse event, so the WindowServer redraws from the driver's state.

  Socket path: $PREVIOUS_ABS_SOCKET (default /tmp/previous-abs.sock).
*/
const char AbsPointer_fileid[] = "Previous abspointer.c";

#include "main.h"
#include "log.h"
#include "kms.h"
#include "abspointer.h"

#include <SDL3/SDL.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>

/* Guest RAM, as allocated by memory_init(): a flat 64 MB buffer whose index is
 * the guest physical address minus 0x04000000 (see cpu/memory.c bank masks). */
extern unsigned char *NEXTRam;
#define ABS_RAM_LEN 0x04000000u

#define ABS_MAX_CAND 65536
#define ABS_QLEN     4096

enum { ABSQ_REL = 1, ABSQ_BTN, ABSQ_NUDGE, ABSQ_ABS };

typedef struct {
	int type;
	int a;
	int b;
} absq_item;

static absq_item absq[ABS_QLEN];
static int absq_r, absq_w;
static SDL_SpinLock absq_lock;

/* Learned location of the event driver's cursorLoc: offset into NEXTRam of a
 * big-endian (int16 x, int16 y) pair. -1 = not learned yet. */
static int32_t absCursorOff = -1;
static uint32_t absCands[ABS_MAX_CAND];
static int absNumCands;
static bool absLeftDown;
static bool absRightDown;

/* ------------------------------------------------------------------ */
/* Guest RAM helpers                                                    */

static int abs_rd16(uint32_t off) {
	return (int16_t)((NEXTRam[off] << 8) | NEXTRam[off + 1]);
}

static void abs_wr16(uint32_t off, int v) {
	NEXTRam[off]     = (v >> 8) & 0xFF;
	NEXTRam[off + 1] = v & 0xFF;
}

/* ------------------------------------------------------------------ */
/* Queue                                                                */

static void absq_put(int type, int a, int b) {
	int n;
	SDL_LockSpinlock(&absq_lock);
	n = absq_w + 1;
	if (n >= ABS_QLEN) n = 0;
	if (n != absq_r) {
		absq[absq_w].type = type;
		absq[absq_w].a    = a;
		absq[absq_w].b    = b;
		absq_w            = n;
	}
	SDL_UnlockSpinlock(&absq_lock);
}

static bool absq_get(absq_item *out) {
	bool ok = false;
	SDL_LockSpinlock(&absq_lock);
	if (absq_r != absq_w) {
		*out   = absq[absq_r];
		absq_r = (absq_r + 1 >= ABS_QLEN) ? 0 : absq_r + 1;
		ok     = true;
	}
	SDL_UnlockSpinlock(&absq_lock);
	return ok;
}

/* ------------------------------------------------------------------ */
/* Executed on the emulation thread, one item per Main_EventHandler tick
 * (200 Hz) — the same scheduling point at which SDL input is drained, so
 * this adds no polling latency the pointer path did not already have. */

void AbsPointer_Poll(void) {
	absq_item it;

	if (!absq_get(&it)) return;

	switch (it.type) {
		case ABSQ_REL:
			kms_mouse_move(it.a, it.b);
			break;
		case ABSQ_BTN:
			if (it.a) absLeftDown = it.b ? true : false;
			else absRightDown = it.b ? true : false;
			kms_mouse_button(it.a ? true : false, it.b ? true : false);
			break;
		case ABSQ_NUDGE:
			kms_mouse_move(0, 0);
			break;
		case ABSQ_ABS:
			if (absCursorOff >= 0) {
				abs_wr16((uint32_t)absCursorOff, it.a);
				abs_wr16((uint32_t)absCursorOff + 2, it.b);
			}
			kms_mouse_move(0, 0);
			break;
		default:
			break;
	}
}

/* ------------------------------------------------------------------ */
/* Candidate scanning                                                   */

static void abs_scan(int xlo, int xhi, int ylo, int yhi) {
	uint32_t o;
	absNumCands = 0;
	if (!NEXTRam) return;
	for (o = 0; o + 4 <= ABS_RAM_LEN; o += 2) {
		int x = abs_rd16(o);
		int y = abs_rd16(o + 2);
		if (x >= xlo && x <= xhi && y >= ylo && y <= yhi) {
			if (absNumCands < ABS_MAX_CAND) absCands[absNumCands++] = o;
		}
	}
}

static void abs_filter(int xlo, int xhi, int ylo, int yhi) {
	int i, n = 0;
	for (i = 0; i < absNumCands; i++) {
		int x = abs_rd16(absCands[i]);
		int y = abs_rd16(absCands[i] + 2);
		if (x >= xlo && x <= xhi && y >= ylo && y <= yhi) absCands[n++] = absCands[i];
	}
	absNumCands = n;
}

/* ------------------------------------------------------------------ */
/* Command interpreter                                                  */

static int abs_hex(const char *s, uint32_t *out) {
	char *e;
	unsigned long v = strtoul(s, &e, 16);
	if (e == s) return 0;
	*out = (uint32_t)v;
	return 1;
}

static void abs_reply(int fd, const char *s) {
	size_t n = strlen(s);
	if (write(fd, s, n) != (ssize_t)n) { /* client gone */
	}
}

static void abs_command(int fd, char *line) {
	char reply[4096];
	char *tok[8];
	int ntok = 0;
	char *p = line;

	while (ntok < 8) {
		while (*p == ' ' || *p == '\t') p++;
		if (!*p) break;
		tok[ntok++] = p;
		while (*p && *p != ' ' && *p != '\t') p++;
		if (*p) *p++ = 0;
	}
	if (ntok == 0) return;

	if (!strcmp(tok[0], "ping")) {
		abs_reply(fd, "ok previous-abspointer 1\n");
	} else if (!strcmp(tok[0], "rel") && ntok >= 3) {
		absq_put(ABSQ_REL, atoi(tok[1]), atoi(tok[2]));
		abs_reply(fd, "ok\n");
	} else if (!strcmp(tok[0], "slam") && ntok >= 4) {
		int i, n = atoi(tok[3]);
		for (i = 0; i < n && i < ABS_QLEN - 2; i++)
			absq_put(ABSQ_REL, atoi(tok[1]), atoi(tok[2]));
		abs_reply(fd, "ok\n");
	} else if (!strcmp(tok[0], "btn") && ntok >= 3) {
		absq_put(ABSQ_BTN, atoi(tok[1]), atoi(tok[2]));
		abs_reply(fd, "ok\n");
	} else if (!strcmp(tok[0], "nudge")) {
		absq_put(ABSQ_NUDGE, 0, 0);
		abs_reply(fd, "ok\n");
	} else if (!strcmp(tok[0], "abs") && ntok >= 3) {
		absq_put(ABSQ_ABS, atoi(tok[1]), atoi(tok[2]));
		abs_reply(fd, "ok\n");
	} else if (!strcmp(tok[0], "setaddr") && ntok >= 2) {
		uint32_t v;
		if (abs_hex(tok[1], &v) && v + 4 <= ABS_RAM_LEN) {
			absCursorOff = (int32_t)v;
			abs_reply(fd, "ok\n");
		} else {
			abs_reply(fd, "err range\n");
		}
	} else if (!strcmp(tok[0], "get")) {
		if (absCursorOff < 0) {
			abs_reply(fd, "err noaddr\n");
		} else {
			snprintf(reply, sizeof(reply), "ok %d %d\n", abs_rd16((uint32_t)absCursorOff),
			         abs_rd16((uint32_t)absCursorOff + 2));
			abs_reply(fd, reply);
		}
	} else if (!strcmp(tok[0], "r") && ntok >= 3) {
		uint32_t off;
		int len = atoi(tok[2]), i, k = 0;
		if (!abs_hex(tok[1], &off) || len <= 0 || len > 1024 || off + len > ABS_RAM_LEN) {
			abs_reply(fd, "err range\n");
		} else {
			k += snprintf(reply + k, sizeof(reply) - k, "ok ");
			for (i = 0; i < len; i++)
				k += snprintf(reply + k, sizeof(reply) - k, "%02x", NEXTRam[off + i]);
			snprintf(reply + k, sizeof(reply) - k, "\n");
			abs_reply(fd, reply);
		}
	} else if (!strcmp(tok[0], "w") && ntok >= 3) {
		uint32_t off;
		size_t i, len = strlen(tok[2]) / 2;
		if (!abs_hex(tok[1], &off) || len == 0 || off + len > ABS_RAM_LEN) {
			abs_reply(fd, "err range\n");
		} else {
			for (i = 0; i < len; i++) {
				char b[3] = {tok[2][i * 2], tok[2][i * 2 + 1], 0};
				NEXTRam[off + i] = (unsigned char)strtoul(b, NULL, 16);
			}
			abs_reply(fd, "ok\n");
		}
	} else if (!strcmp(tok[0], "scan") && ntok >= 5) {
		abs_scan(atoi(tok[1]), atoi(tok[2]), atoi(tok[3]), atoi(tok[4]));
		snprintf(reply, sizeof(reply), "ok %d\n", absNumCands);
		abs_reply(fd, reply);
	} else if (!strcmp(tok[0], "filt") && ntok >= 5) {
		abs_filter(atoi(tok[1]), atoi(tok[2]), atoi(tok[3]), atoi(tok[4]));
		snprintf(reply, sizeof(reply), "ok %d\n", absNumCands);
		abs_reply(fd, reply);
	} else if (!strcmp(tok[0], "cands")) {
		int i, k = 0, lim = absNumCands > 64 ? 64 : absNumCands;
		k += snprintf(reply + k, sizeof(reply) - k, "ok %d", absNumCands);
		for (i = 0; i < lim; i++)
			k += snprintf(reply + k, sizeof(reply) - k, " %x:%d,%d", absCands[i],
			              abs_rd16(absCands[i]), abs_rd16(absCands[i] + 2));
		snprintf(reply + k, sizeof(reply) - k, "\n");
		abs_reply(fd, reply);
	} else {
		abs_reply(fd, "err unknown\n");
	}
}

/* ------------------------------------------------------------------ */

static int abs_thread(void *arg) {
	int srv = (int)(intptr_t)arg;

	for (;;) {
		char buf[8192];
		size_t used = 0;
		int cli = accept(srv, NULL, NULL);
		if (cli < 0) {
			if (errno == EINTR) continue;
			break;
		}
		for (;;) {
			ssize_t n = read(cli, buf + used, sizeof(buf) - used - 1);
			char *nl;
			if (n <= 0) break;
			used += (size_t)n;
			buf[used] = 0;
			while ((nl = strchr(buf, '\n')) != NULL) {
				*nl = 0;
				abs_command(cli, buf);
				memmove(buf, nl + 1, used - (size_t)(nl + 1 - buf) + 1);
				used -= (size_t)(nl + 1 - buf);
			}
			if (used >= sizeof(buf) - 1) used = 0;
		}
		close(cli);
	}
	return 0;
}

void AbsPointer_Init(void) {
	const char *path = getenv("PREVIOUS_ABS_SOCKET");
	struct sockaddr_un sa;
	int srv;

	if (!path) path = "/tmp/previous-abs.sock";
	if (strlen(path) >= sizeof(sa.sun_path)) return;

	srv = socket(AF_UNIX, SOCK_STREAM, 0);
	if (srv < 0) return;
	unlink(path);
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	strcpy(sa.sun_path, path);
	if (bind(srv, (struct sockaddr *)&sa, sizeof(sa)) < 0 || listen(srv, 4) < 0) {
		close(srv);
		return;
	}
	Log_Printf(LOG_WARN, "[AbsPointer] control channel on %s", path);
	SDL_CreateThread(abs_thread, "[Previous] abs pointer", (void *)(intptr_t)srv);
}
