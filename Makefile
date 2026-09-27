SDK := $(shell xcrun --show-sdk-path)
CFLAGS := -fobjc-arc -Wall -Wextra -F$(SDK)/System/Library/PrivateFrameworks
LDLIBS := -framework Foundation -framework CoreBrightness
PREFIX ?= /usr/local
SHARED := NightShift.m NightShift.h CBBlueLightClient.h

all: nightshift nightshiftd

nightshift: main.m $(SHARED)
	clang $(CFLAGS) $(LDLIBS) -o $@ main.m NightShift.m

nightshiftd: nightshiftd.m $(SHARED)
	clang $(CFLAGS) $(LDLIBS) -o $@ nightshiftd.m NightShift.m

install: all
	install -d $(PREFIX)/bin
	install -m 755 nightshift nightshiftd $(PREFIX)/bin

clean:
	rm -f nightshift nightshiftd

.PHONY: all install clean
