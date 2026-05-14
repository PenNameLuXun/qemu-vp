TARGET  := egl-wayland-demo
CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra

# locate xdg-shell.xml + wayland-scanner via pkg-config
WAYLAND_PROTOCOLS_DIR := $(shell pkg-config --variable=pkgdatadir wayland-protocols)
SCANNER               := $(shell pkg-config --variable=wayland_scanner wayland-scanner)
XDG_SHELL_XML         := $(WAYLAND_PROTOCOLS_DIR)/stable/xdg-shell/xdg-shell.xml

PKGS    := wayland-client wayland-egl egl glesv2
CFLAGS  += $(shell pkg-config --cflags $(PKGS))
LIBS    := $(shell pkg-config --libs   $(PKGS)) -lm

GEN_HDR := xdg-shell-client-protocol.h
GEN_SRC := xdg-shell-protocol.c

$(TARGET): main.c $(GEN_HDR) $(GEN_SRC)
	$(CC) $(CFLAGS) -o $@ main.c $(GEN_SRC) $(LIBS)

$(GEN_HDR): $(XDG_SHELL_XML)
	$(SCANNER) client-header $< $@

$(GEN_SRC): $(XDG_SHELL_XML)
	$(SCANNER) private-code $< $@

clean:
	rm -f $(TARGET) $(GEN_HDR) $(GEN_SRC)

.PHONY: clean
