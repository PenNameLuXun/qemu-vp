TARGET  := egl-x11-demo
CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
PKGS    := x11 egl glesv2
CFLAGS  += $(shell pkg-config --cflags $(PKGS))
LIBS    := $(shell pkg-config --libs   $(PKGS)) -lm

$(TARGET): main.c
	$(CC) $(CFLAGS) -o $@ $< $(LIBS)

clean:
	rm -f $(TARGET)

.PHONY: clean
