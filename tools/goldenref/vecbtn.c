/* vecbtn - vecdump variant with a scriptable button/joystick timeline.
 *
 * Purpose: discover, in simulation, the exact input sequence that walks the
 * GCE Test Cartridge to a given screen, so the hardware loop can replay it
 * through the uinput virtual pad.
 *
 * Buttons are PSG IO port A (snd_regs[14]), active low, bits 0-3 = player 1
 * buttons 1-4. Joystick is alg_jch0/1 (P1 X/Y), 0x80 centered.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vecx.h"
#include "osint.h"

void e8910_init_sound(void) {}
void e8910_done_sound(void) {}
void e8910_write(int r, int v) { (void)r; (void)v; }

#define MAX_EV 64
static struct { long start, len; unsigned mask; int jx, jy; } ev[MAX_EV];
static int n_ev = 0;

static long frame_index = 0, until = 1000, dump_every = 0;
static long dump_list[256]; static int n_dump = 0;
static const char *out_dir = ".";
static int pgm_w = 330, pgm_h = 410, done = 0;
static unsigned char *fb;

static void plot(int x, int y, int c)
{
	int v;
	if (x < 0 || y < 0 || x >= pgm_w || y >= pgm_h) return;
	v = fb[y * pgm_w + x] + c;
	fb[y * pgm_w + x] = (v > 255) ? 255 : (unsigned char)v;
}

static void draw_line(int x0, int y0, int x1, int y1, int c)
{
	int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
	int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
	int err = dx + dy, e2;
	for (;;) {
		plot(x0, y0, c);
		if (x0 == x1 && y0 == y1) break;
		e2 = 2 * err;
		if (e2 >= dy) { err += dy; x0 += sx; }
		if (e2 <= dx) { err += dx; y0 += sy; }
	}
}

static void render_pgm(long idx)
{
	char path[512];
	FILE *f;
	long i;
	memset(fb, 0, (size_t)pgm_w * pgm_h);
	for (i = 0; i < vector_draw_cnt; i++) {
		int x0 = (int)((long long)vectors_draw[i].x0 * pgm_w / ALG_MAX_X);
		int x1 = (int)((long long)vectors_draw[i].x1 * pgm_w / ALG_MAX_X);
		int y0 = (int)((long long)vectors_draw[i].y0 * pgm_h / ALG_MAX_Y);
		int y1 = (int)((long long)vectors_draw[i].y1 * pgm_h / ALG_MAX_Y);
		draw_line(x0, y0, x1, y1, (int)vectors_draw[i].color * 2);
	}
	snprintf(path, sizeof path, "%s/f%05ld.pgm", out_dir, idx);
	f = fopen(path, "wb");
	if (!f) { perror(path); return; }
	fprintf(f, "P5\n%d %d\n255\n", pgm_w, pgm_h);
	fwrite(fb, 1, (size_t)pgm_w * pgm_h, f);
	fclose(f);
}

void osint_render(void)
{
	int i, want = 0;
	unsigned mask = 0;
	int jx = 0x80, jy = 0x80;

	for (i = 0; i < n_ev; i++)
		if (frame_index >= ev[i].start && frame_index < ev[i].start + ev[i].len) {
			mask |= ev[i].mask;
			if (ev[i].jx >= 0) jx = ev[i].jx;
			if (ev[i].jy >= 0) jy = ev[i].jy;
		}
	snd_regs[14] = 0xff & ~mask;
	alg_jch0 = (unsigned)jx;
	alg_jch1 = (unsigned)jy;

	if (dump_every && frame_index % dump_every == 0) want = 1;
	for (i = 0; i < n_dump; i++) if (dump_list[i] == frame_index) want = 1;
	if (want) {
		render_pgm(frame_index);
		printf("frame %5ld: %6ld segments\n", frame_index, vector_draw_cnt);
	}
	if (++frame_index >= until) done = 1;
}

static int load(const char *path, unsigned char *buf, size_t max, const char *what)
{
	FILE *f = fopen(path, "rb");
	size_t n;
	if (!f) { fprintf(stderr, "cannot open %s: %s\n", what, path); return -1; }
	n = fread(buf, 1, max, f);
	fclose(f);
	fprintf(stderr, "loaded %s: %s (%zu bytes)\n", what, path, n);
	return 0;
}

int main(int argc, char **argv)
{
	const char *bios = NULL, *cartf = NULL, *fill = "zero";
	int i;

	for (i = 1; i < argc; i++) {
		if      (!strcmp(argv[i], "--bios") && i + 1 < argc) bios = argv[++i];
		else if (!strcmp(argv[i], "--cart") && i + 1 < argc) cartf = argv[++i];
		else if (!strcmp(argv[i], "--fill") && i + 1 < argc) fill = argv[++i];
		else if (!strcmp(argv[i], "--until") && i + 1 < argc) until = atol(argv[++i]);
		else if (!strcmp(argv[i], "--every") && i + 1 < argc) dump_every = atol(argv[++i]);
		else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump_list[n_dump++] = atol(argv[++i]);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc) out_dir = argv[++i];
		else if (!strcmp(argv[i], "--press") && i + 1 < argc) {
			/* --press START:LEN:MASK   (mask bit N = P1 button N+1) */
			long s, l; unsigned m;
			if (sscanf(argv[++i], "%ld:%ld:%x", &s, &l, &m) != 3) return 1;
			ev[n_ev].start = s; ev[n_ev].len = l; ev[n_ev].mask = m;
			ev[n_ev].jx = -1; ev[n_ev].jy = -1; n_ev++;
		}
		else if (!strcmp(argv[i], "--joy") && i + 1 < argc) {
			/* --joy START:LEN:X:Y  (0..255, 128 centered) */
			long s, l; int x, y;
			if (sscanf(argv[++i], "%ld:%ld:%d:%d", &s, &l, &x, &y) != 4) return 1;
			ev[n_ev].start = s; ev[n_ev].len = l; ev[n_ev].mask = 0;
			ev[n_ev].jx = x; ev[n_ev].jy = y; n_ev++;
		}
		else { fprintf(stderr, "bad arg %s\n", argv[i]); return 1; }
	}
	if (!bios) return 1;

	memset(rom, 0, sizeof rom);
	memset(cart, 0, sizeof cart);
	if (load(bios, rom, sizeof rom, "bios") < 0) return 1;
	if (cartf) {
		FILE *cf = fopen(cartf, "rb");
		long clen;
		if (!cf) { perror(cartf); return 1; }
		clen = (long)fread(cart, 1, sizeof cart, cf);
		fclose(cf);
		fprintf(stderr, "loaded cart: %s (%ld bytes, fill=%s)\n", cartf, clen, fill);
		if (clen > 0 && clen < (long)sizeof cart) {
			long a;
			if (!strcmp(fill, "ff"))
				memset(cart + clen, 0xff, sizeof cart - clen);
			else if (!strcmp(fill, "mirror"))
				for (a = clen; a < (long)sizeof cart; a++)
					cart[a] = cart[a % clen];
		}
	}

	fb = calloc((size_t)pgm_w * pgm_h, 1);
	alg_jch0 = alg_jch1 = alg_jch2 = alg_jch3 = 0x80;
	vecx_reset();
	while (!done)
		vecx_emu(VECTREX_MHZ / 1000);
	return 0;
}
