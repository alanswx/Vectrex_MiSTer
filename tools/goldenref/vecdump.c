/* vecdump - headless golden-reference vector dumper for the Vectrex core.
 *
 * Links against the vecx emulator (kept in refs/vecx, not vendored here) and
 * captures the analytic line-segment list vecx produces for each frame. That
 * list is the reference the FPGA core's renderer is validated against.
 *
 * vecx calls osint_render() at every frame boundary, before it swaps the draw
 * and erase vector lists. Supplying our own osint_render() gives us the frame
 * hook without modifying vecx at all. The e8910 stubs exist only so we can
 * link without pulling in SDL.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vecx.h"
#include "osint.h"

/* ---- audio stubs: vecx references these, we do not want SDL ------------- */
void e8910_init_sound(void) {}
void e8910_done_sound(void) {}
void e8910_write(int r, int v) { (void)r; (void)v; }

/* ---- capture state ------------------------------------------------------ */
static long frame_index    = 0;   /* frames seen since reset */
static long frames_to_skip = 0;   /* boot frames discarded before capture */
static long frames_to_dump = 0;   /* frames captured after the skip */
static long frames_dumped  = 0;
static const char *out_dir = ".";
static int   pgm_w = 0, pgm_h = 0;   /* 0 disables PGM rendering */
static int   done  = 0;

/* ---- PGM rendering ------------------------------------------------------
 * Deliberately simple: additive Bresenham so overlapping vectors accumulate
 * brightness the way phosphor does. This is for eyeballing and coarse image
 * diffing, not a model of the CRT.
 */
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
	int dx =  abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
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

static void render_pgm(const vector_t *v, long n, long idx)
{
	char path[512];
	FILE *f;
	long i;

	memset(fb, 0, (size_t)pgm_w * pgm_h);

	for (i = 0; i < n; i++) {
		/* vecx's coordinate space is already top-down, matching PGM order
		 * (its own SDL frontend maps x/y straight through). */
		int x0 = (int)((long long)v[i].x0 * pgm_w / ALG_MAX_X);
		int x1 = (int)((long long)v[i].x1 * pgm_w / ALG_MAX_X);
		int y0 = (int)((long long)v[i].y0 * pgm_h / ALG_MAX_Y);
		int y1 = (int)((long long)v[i].y1 * pgm_h / ALG_MAX_Y);
		draw_line(x0, y0, x1, y1, v[i].color * 2);
	}

	snprintf(path, sizeof path, "%s/frame%04ld.pgm", out_dir, idx);
	f = fopen(path, "wb");
	if (!f) { perror(path); return; }
	fprintf(f, "P5\n%d %d\n255\n", pgm_w, pgm_h);
	fwrite(fb, 1, (size_t)pgm_w * pgm_h, f);
	fclose(f);
}

/* ---- the frame hook vecx calls ----------------------------------------- */
void osint_render(void)
{
	char path[512];
	FILE *f;
	long i, idx;

	if (done) return;

	if (frame_index++ < frames_to_skip) return;

	idx = frames_dumped;

	snprintf(path, sizeof path, "%s/frame%04ld.vec", out_dir, idx);
	f = fopen(path, "w");
	if (!f) { perror(path); exit(1); }

	/* At this point vectors_draw holds the frame that just completed; the
	 * swap into vectors_erse happens after this call returns. */
	fprintf(f, "# frame %ld  segments %ld  space %dx%d\n",
	        idx, vector_draw_cnt, ALG_MAX_X, ALG_MAX_Y);
	fprintf(f, "# x0 y0 x1 y1 color\n");
	for (i = 0; i < vector_draw_cnt; i++)
		fprintf(f, "%ld %ld %ld %ld %u\n",
		        vectors_draw[i].x0, vectors_draw[i].y0,
		        vectors_draw[i].x1, vectors_draw[i].y1,
		        vectors_draw[i].color);
	fclose(f);

	if (pgm_w) render_pgm(vectors_draw, vector_draw_cnt, idx);

	printf("frame %4ld: %6ld segments\n", idx, vector_draw_cnt);

	if (++frames_dumped >= frames_to_dump) done = 1;
}

/* ---- loading ------------------------------------------------------------ */
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

static void usage(const char *p)
{
	fprintf(stderr,
	    "usage: %s --bios rom.dat [--cart game.bin] [options]\n"
	    "  --frames N   frames to capture (default 1)\n"
	    "  --skip N     boot frames to discard first (default 400)\n"
	    "               A frame here is vecx's phosphor-decay period (1/30 s),\n"
	    "               not a display refresh. The BIOS announcement runs for\n"
	    "               roughly 350 of them, and every cart looks identical\n"
	    "               until it ends, so skip past it before capturing.\n"
	    "  --out DIR    output directory (default .)\n"
	    "  --pgm WxH    also render each frame to a PGM image\n", p);
}

int main(int argc, char **argv)
{
	const char *bios = NULL, *cartf = NULL;
	int i;

	frames_to_dump = 1;
	frames_to_skip = 400;

	for (i = 1; i < argc; i++) {
		if      (!strcmp(argv[i], "--bios")   && i + 1 < argc) bios  = argv[++i];
		else if (!strcmp(argv[i], "--cart")   && i + 1 < argc) cartf = argv[++i];
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames_to_dump = atol(argv[++i]);
		else if (!strcmp(argv[i], "--skip")   && i + 1 < argc) frames_to_skip = atol(argv[++i]);
		else if (!strcmp(argv[i], "--out")    && i + 1 < argc) out_dir = argv[++i];
		else if (!strcmp(argv[i], "--pgm")    && i + 1 < argc) {
			if (sscanf(argv[++i], "%dx%d", &pgm_w, &pgm_h) != 2) { usage(argv[0]); return 1; }
		}
		else { usage(argv[0]); return 1; }
	}

	if (!bios) { usage(argv[0]); return 1; }

	memset(rom,  0, sizeof rom);
	memset(cart, 0, sizeof cart);
	if (load(bios, rom, sizeof rom, "bios") < 0) return 1;
	if (cartf && load(cartf, cart, sizeof cart, "cart") < 0) return 1;

	if (pgm_w) {
		fb = calloc((size_t)pgm_w * pgm_h, 1);
		if (!fb) { fprintf(stderr, "out of memory\n"); return 1; }
	}

	/* Centre both joystick axes so nothing drifts while we capture. */
	alg_jch0 = alg_jch1 = alg_jch2 = alg_jch3 = 0x80;

	vecx_reset();

	/* One vecx_emu() call per emulated millisecond keeps the frame hook
	 * firing at a natural granularity. */
	while (!done)
		vecx_emu(VECTREX_MHZ / 1000);

	fprintf(stderr, "captured %ld frame(s) to %s\n", frames_dumped, out_dir);
	return 0;
}
