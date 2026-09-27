SDK := $(shell xcrun --show-sdk-path)
CFLAGS := -fobjc-arc -F$(SDK)/System/Library/PrivateFrameworks
LDLIBS := -framework Foundation -framework CoreBrightness
PREFIX ?= /usr/local

all: nightshift nightshiftd

nightshift: main.m CBBlueLightClient.h
	clang $(CFLAGS) $(LDLIBS) -o $@ main.m

nightshiftd: nightshiftd.m CBBlueLightClient.h
	clang $(CFLAGS) $(LDLIBS) -o $@ nightshiftd.m

install: all
	install -d $(PREFIX)/bin
	install -m 755 nightshift nightshiftd $(PREFIX)/bin

clean:
	rm -f nightshift nightshiftd

.PHONY: all install clean
