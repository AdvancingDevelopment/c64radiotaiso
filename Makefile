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

# -soundsync 2 = "exact": VICE keeps the emulated frame rate steady and lets the audio
# adapt (the default flexible sync can duplicate/drop displayed frames under the 5 kHz
# digi load, which shows up as scrolling-text stutter on the host — not on real hardware)
VICEOPTS ?= -soundsync 2 -soundbufsize 100

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
