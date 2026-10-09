SDK := $(shell xcrun --show-sdk-path)
CFLAGS := -fobjc-arc -Wall -Wextra -F$(SDK)/System/Library/PrivateFrameworks
LDLIBS := -framework Foundation -framework CoreBrightness -framework Security
PREFIX ?= /usr/local
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
SHARED := NightShift.m NightShift.h CBBlueLightClient.h
APP := Nightshift.app
BUNDLED := $(APP)/Contents/MacOS/nightshiftd
DIST := dist
STAGE := $(DIST)/root
ZIP := $(DIST)/Nightshift.zip

all: nightshift nightshiftd $(BUNDLED)

test: nightshift nightshift-tests
	./nightshift-tests
	sh tests/cli.sh

nightshift: main.m $(SHARED)
	clang $(CFLAGS) $(LDLIBS) -o $@ main.m NightShift.m

nightshiftd: nightshiftd.m $(SHARED)
	clang $(CFLAGS) $(LDLIBS) -framework AppKit -framework UserNotifications -framework ServiceManagement -framework CoreGraphics -framework IOKit -framework DisplayServices -framework SkyLight -o $@ nightshiftd.m NightShift.m

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

package: all
	rm -rf $(STAGE) $(ZIP)
	mkdir -p $(STAGE)/bin
	install -m 755 nightshift $(STAGE)/bin/nightshift
	cp -R $(APP) $(STAGE)/
	codesign --force --sign - $(STAGE)/bin/nightshift
	ditto -c -k --norsrc $(STAGE) $(ZIP)
	rm -rf $(STAGE)
	@echo $(ZIP) $(VERSION)

clean:
	rm -rf nightshift nightshiftd nightshift-tests $(APP) $(DIST)

icon-lab:
	open prototype/icon/index.html

.PHONY: all test install package clean icon-lab
