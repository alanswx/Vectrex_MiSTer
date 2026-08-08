# Builds the golden-reference vector dumper.
#
# vecx is NOT vendored into this repo. Clone it alongside the other reference
# checkouts and point VECX at it:
#
#   git clone https://github.com/jhawthorn/vecx refs/vecx
#   make -C tools/goldenref
#
# Only vecx.c and e6809.c are compiled; the SDL frontend (osint.c) and the
# audio backend (e8910.c) are replaced by hooks and stubs in vecdump.c.
#
# vecx defines `einline` as `static __inline` and then writes `static einline`,
# which expands to a duplicate `static`. That was tolerated by the compilers of
# its day but is a constraint violation modern GCC rejects. We strip the
# redundant `static` into a local copy at build time (leaving the macro alone,
# since e6809.c also uses `einline` bare) so refs/vecx stays pristine.

VECX  ?= ../../refs/vecx
CC    ?= cc
CFLAGS?= -O2 -Wall -Wextra -Wno-unused-parameter -I$(VECX)

OBJS = vecdump.o vecx.o e6809.o
GEN  = gen_vecx.c gen_e6809.c

all: vecdump vecbtn

vecdump: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

vecdump.o: vecdump.c
	$(CC) $(CFLAGS) -c -o $@ $<

vecbtn: vecbtn.o vecx.o e6809.o
	$(CC) $(CFLAGS) -o $@ vecbtn.o vecx.o e6809.o

vecbtn.o: vecbtn.c
	$(CC) $(CFLAGS) -c -o $@ $<

gen_%.c: $(VECX)/%.c
	sed 's/^static einline/einline/' $< > $@

vecx.o: gen_vecx.c
	$(CC) $(CFLAGS) -c -o $@ $<

e6809.o: gen_e6809.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f vecdump vecbtn vecbtn.o $(OBJS) $(GEN)

.PHONY: all clean
