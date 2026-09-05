# Radio Taiso 64 — build with ACME, run/test with VICE
ACME  ?= acme
X64SC ?= x64sc
PY    ?= python3
NODE  ?= node
VERSION ?= 1.0

SRC := $(wildcard src/*.asm)

build/taiso.prg: $(SRC)
	@mkdir -p build
	$(ACME) --symbollist build/taiso.sym src/main.asm
	@$(PY) tools/memreport.py build/taiso.sym build/taiso.prg

.PHONY: run run-pal test clean gen d64 release

# VICE 3.10: host vsync on. -sidmodel 1 = 8580 (the default C64C sound).
# Use -sidmodel 0 for the older 6581 filter if you prefer it.
# +saveres: never persist these flags into ~/.config/vice/vicerc (that file has
# SaveResourcesOnExit=1; a saved dummy-sound + off-screen-window config once
# made `make run` silent and invisible). -ntsc/-pal are explicit for the same
# reason. NTSC is the project's default system; `make run-pal` for PAL.
VICEOPTS ?= -VICIIvsync -sidmodel 1 -residsamp 1

run: build/taiso.prg
	$(X64SC) $(VICEOPTS) -ntsc +saveres -autostartprgmode 1 build/taiso.prg

run-pal: build/taiso.prg
	$(X64SC) $(VICEOPTS) -pal +saveres -autostartprgmode 1 build/taiso.prg

test: build/taiso.prg
	./test/run_tests.sh

d64: build/taiso.prg
	c1541 -format "radio taiso,rt" d64 build/taiso.d64 -write build/taiso.prg taiso

# release kit (prg, d64, README.txt, screenshots, itch cover, zip) -> build/release/
release: build/taiso.prg
	./tools/release.sh $(VERSION)

clean:
	rm -rf build
