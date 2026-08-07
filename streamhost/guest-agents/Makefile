# guest-agents/Makefile — build the in-guest streamhost pointer agents with the
# EXACT proven toolchains, ON THE BOX (Debian/Proxmox host).
#
# Each guest agent speaks the daemon's newline M/P/R/B(/C/D/U/W) protocol reached
# over a QEMU hostfwd (or COM1 for OS/2). This Makefile only COMPILES the agents;
# delivery into a guest golden is a separate bake step (see solaris/golden-warpd-bake.sh).
#
# Targets:
#   make win9x      Win95/98SE  : i686-w64-mingw32-gcc  -> win9x/warpnet.exe
#   make os2        OS/2 Warp   : OpenWatcom 1.9 wcl386 -> os2/WARPD.EXE
#   make solaris    Solaris CDE : NO build (python2.6 runs in-guest) — validates only
#   make ninefront  9front/Plan9: NO host build (6c/6l run in-guest) — prints recipe
#   make all        every agent that CAN build on this host
#   make check      report which toolchains are present/missing (builds nothing)
#   make clean      remove built artifacts
#
# Where a toolchain is MISSING on the box, the target PRINTS install instructions
# and exits 0 (it does not fail silently and does not error the whole run).
#
# Run on the box:  cd /data/vms/streamhost/build/guest-agents && make <target>

HERE     := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
WIN9X_C  := $(HERE)win9x/warpnet.c
WIN9X_X  := $(HERE)win9x/warpnet.exe
OS2_C    := $(HERE)os2/warpd_os2.c
OS2_X    := $(HERE)os2/WARPD.EXE
SOLARIS_PY := $(HERE)solaris/warpd.py
NINE_C   := $(HERE)ninefront/warpd.c

MINGW    := i686-w64-mingw32-gcc
WCL386   := wcl386

.PHONY: all check clean win9x os2 solaris ninefront

all: win9x os2 solaris ninefront
	@echo "== guest-agents: all buildable targets done =="

# ---- Win95 / Win98SE : warpnet.exe -------------------------------------------
# Proven: i686-w64-mingw32-gcc -O2 -s -mwindows -Wl,--no-insert-timestamp -o warpnet.exe warpnet.c -lwsock32
#   -mwindows => GUI subsystem (no DOS box in the guest). -s strips. Suppressing
#   the PE timestamp makes repeated builds byte-identical.
win9x:
	@if command -v $(MINGW) >/dev/null 2>&1; then \
	  echo "[win9x] $(MINGW) -O2 -s -mwindows -Wl,--no-insert-timestamp -o warpnet.exe warpnet.c -lwsock32"; \
	  cd $(HERE)win9x && $(MINGW) -O2 -s -mwindows -Wl,--no-insert-timestamp -o warpnet.exe warpnet.c -lwsock32 && \
	  echo "[win9x] OK -> $(WIN9X_X)" && file warpnet.exe 2>/dev/null || true; \
	else \
	  echo "[win9x] MISSING toolchain: $(MINGW)"; \
	  echo "        install on Debian/Proxmox:"; \
	  echo "          apt-get update && apt-get install -y gcc-mingw-w64-i686"; \
	  echo "        (provides $(MINGW)); then re-run: make win9x"; \
	fi

# ---- OS/2 Warp : WARPD.EXE (32-bit PM EXE) -----------------------------------
# Proven: wcl386 -bt=os2 -l=os2v2_pm -fe=WARPD.EXE warpd_os2.c   (OpenWatcom 1.9)
os2:
	@if command -v $(WCL386) >/dev/null 2>&1; then \
	  echo "[os2] $(WCL386) -bt=os2 -l=os2v2_pm -fe=WARPD.EXE warpd_os2.c"; \
	  cd $(HERE)os2 && $(WCL386) -bt=os2 -l=os2v2_pm -fe=WARPD.EXE warpd_os2.c && \
	  echo "[os2] OK -> $(OS2_X)"; \
	else \
	  echo "[os2] MISSING toolchain: OpenWatcom 1.9 ($(WCL386))"; \
	  echo "        install on Debian/Proxmox (headless cross to OS/2) — MUST be the pinned 1.9,"; \
	  echo "        NOT V2: the V2 runtime crashes on OS/2 Warp 4 GA (docs/guests/os2warp.md)."; \
	  echo "          cd /opt && curl -fsSLO https://downloads.sourceforge.net/openwatcom/open-watcom-c-linux-1.9"; \
	  echo "          sh ./open-watcom-c-linux-1.9   # installer; target dir /opt/watcom"; \
	  echo "          export WATCOM=/opt/watcom PATH=/opt/watcom/binl:\$$PATH   # 1.9 ships binl only (32-bit)"; \
	  echo "          export INCLUDE=/opt/watcom/h:/opt/watcom/h/os2 EDPATH=/opt/watcom/eddat"; \
	  echo "        then re-run: make os2"; \
	fi

# ---- Solaris CDE : NO host build (python2.6 runs in-guest) -------------------
# The agent is /opt/warpd/warpd.py (guest python2.6). Nothing to compile on the
# host. Validate the source exists and, if a python2 is around, syntax-check it.
solaris:
	@echo "[solaris] no host build — python2.6 runs IN-GUEST (/opt/warpd/warpd.py, TCP :7777)"
	@if [ -f "$(SOLARIS_PY)" ]; then echo "[solaris] source present: $(SOLARIS_PY)"; else echo "[solaris] MISSING source: $(SOLARIS_PY)"; fi
	@if command -v python2 >/dev/null 2>&1; then \
	  python2 -m py_compile "$(SOLARIS_PY)" && echo "[solaris] py_compile OK (python2 syntax)"; \
	else \
	  echo "[solaris] (no host python2 to syntax-check; guest ships python2.6 — this is expected)"; \
	fi
	@echo "[solaris] deliver via: bash solaris/golden-warpd-bake.sh  (host http.server + in-guest urllib fetch)"

# ---- 9front / Plan 9 : NO host build (6c/6l run in-guest) --------------------
ninefront:
	@echo "[ninefront] no host build — Plan 9 C, compiled IN-GUEST with the 9front toolchain."
	@if [ -f "$(NINE_C)" ]; then echo "[ninefront] source present: $(NINE_C)"; else echo "[ninefront] MISSING source: $(NINE_C)"; fi
	@echo "        deliver warpd.c into the guest, then in a 9front rc shell:"
	@echo "          6c warpd.c && 6l -o warpd warpd.6 && ./warpd   # listens tcp!*!7777"
	@echo "        (live guest is amd64: 6c/6l; a 386 guest would be 8c/8l). Injects via /dev/mousein 'A x y buttons'."

check:
	@echo "== guest-agents toolchain check =="
	@printf 'win9x    (%s): ' "$(MINGW)";  command -v $(MINGW)  >/dev/null 2>&1 && echo present || echo "MISSING -> apt-get install gcc-mingw-w64-i686"
	@printf 'os2      (%s): ' "$(WCL386)"; command -v $(WCL386) >/dev/null 2>&1 && echo present || echo "MISSING -> install OpenWatcom 1.9 (make os2 for steps)"
	@printf 'solaris  (in-guest python2.6): n/a on host\n'
	@printf 'ninefront(in-guest 6c/6l)   : n/a on host\n'

clean:
	@rm -f "$(WIN9X_X)" "$(OS2_X)" $(HERE)os2/*.o $(HERE)win9x/*.o
	@echo "[clean] removed built agent artifacts"
