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

# VICE 3.10: host vsync on, a large sound buffer so the audio side never has to stretch
# the stream (a small buffer under the 5 kHz digi load can make VICE duplicate/drop displayed
# frames, which shows up as scrolling-text stutter on the host — not on real hardware)
VICEOPTS ?= -VICIIvsync -soundbufsize 150 -soundfragsize 3

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
