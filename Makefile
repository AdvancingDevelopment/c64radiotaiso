# Radio Taiso 64 — build with ACME, run/test with VICE
ACME  ?= acme
X64SC ?= x64sc
PY    ?= python3
NODE  ?= node

SRC := $(wildcard src/*.asm)

build/taiso.prg: $(SRC)
	@mkdir -p build
	$(ACME) --symbollist build/taiso.sym src/main.asm
	@$(PY) tools/memreport.py build/taiso.sym build/taiso.prg

.PHONY: run test clean gen d64

# VICE 3.10: host vsync on. -sidmodel 0 = 6581: the SID music (filter routing, cutoff
# sweeps) is tuned on the 6581; VICE defaults to the 8580 here, whose filter sounds
# different. Use -sidmodel 1 for the 8580 if you prefer it.
VICEOPTS ?= -VICIIvsync -sidmodel 0 -residsamp 1

run: build/taiso.prg
	$(X64SC) $(VICEOPTS) -autostartprgmode 1 build/taiso.prg

run-ntsc: build/taiso.prg
	$(X64SC) $(VICEOPTS) -ntsc -autostartprgmode 1 build/taiso.prg

test: build/taiso.prg
	./test/run_tests.sh

d64: build/taiso.prg
	c1541 -format "radio taiso,rt" d64 build/taiso.d64 -write build/taiso.prg taiso

clean:
	rm -rf build
