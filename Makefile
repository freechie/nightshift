SDK := $(shell xcrun --show-sdk-path)
CFLAGS := -fobjc-arc -Wall -Wextra -F$(SDK)/System/Library/PrivateFrameworks
LDLIBS := -framework Foundation -framework CoreBrightness
PREFIX ?= /usr/local
SHARED := NightShift.m NightShift.h CBBlueLightClient.h
APP := Nightshift.app
BUNDLED := $(APP)/Contents/MacOS/nightshiftd

all: nightshift nightshiftd $(BUNDLED)

test: nightshift nightshift-tests
	./nightshift-tests
	sh tests/cli.sh

nightshift: main.m $(SHARED)
	clang $(CFLAGS) $(LDLIBS) -o $@ main.m NightShift.m

nightshiftd: nightshiftd.m $(SHARED)
	clang $(CFLAGS) $(LDLIBS) -framework AppKit -framework UserNotifications -o $@ nightshiftd.m NightShift.m

nightshift-tests: tests/check.m $(SHARED)
	clang $(CFLAGS) -I. $(LDLIBS) -o $@ tests/check.m NightShift.m

$(BUNDLED): nightshiftd Info.plist
	mkdir -p $(dir $@)
	cp Info.plist $(APP)/Contents/
	cp nightshiftd $@
	codesign --force --sign - $(APP)

install: all
	install -d $(PREFIX)/bin
	install -m 755 nightshift $(PREFIX)/bin
	rm -rf $(PREFIX)/Nightshift.app
	cp -R Nightshift.app $(PREFIX)/Nightshift.app

clean:
	rm -rf nightshift nightshiftd nightshift-tests $(APP)

.PHONY: all test install clean
