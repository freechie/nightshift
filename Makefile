SDK := $(shell xcrun --show-sdk-path)
CFLAGS := -fobjc-arc -Wall -Wextra -F$(SDK)/System/Library/PrivateFrameworks
LDLIBS := -framework Foundation -framework CoreBrightness -framework Security
PREFIX ?= /usr/local
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
SHARED := NightShift.m NightShift.h CBBlueLightClient.h
LOGIC := NightshiftLogic.m NightshiftLogic.h
APP := Nightshift.app
BUNDLED := $(APP)/Contents/MacOS/nightshiftd
DIST := dist
STAGE := $(DIST)/root
ZIP := $(DIST)/Nightshift.zip

all: nightshift nightshiftd $(BUNDLED)

test: nightshift nightshift-tests logic-tests server-test
	./nightshift-tests
	./logic-tests
	sh tests/cli.sh

# The license server's tests: test.js needs only Node; prove.js also runs
# the license command of nightshift-testkey. Both sign with a throwaway key.
server-test: nightshift-testkey
	@test -d server/node_modules || { echo "server/node_modules is missing: run (cd server && npm ci)" >&2; exit 1; }
	cd server && node test.js
	cd server && node prove.js

nightshift: main.m $(SHARED)
	clang $(CFLAGS) $(LDLIBS) -o $@ main.m NightShift.m

nightshiftd: nightshiftd.m $(SHARED) $(LOGIC)
	clang $(CFLAGS) $(LDLIBS) -framework AppKit -framework UserNotifications -framework ServiceManagement -framework CoreGraphics -framework IOKit -framework DisplayServices -framework SkyLight -o $@ nightshiftd.m NightShift.m NightshiftLogic.m

nightshift-tests: tests/check.m $(SHARED)
	clang $(CFLAGS) -I. $(LDLIBS) -o $@ tests/check.m NightShift.m

logic-tests: tests/logic.m $(LOGIC)
	clang $(CFLAGS) -I. -o $@ tests/logic.m NightshiftLogic.m

# The CLI with NIGHTSHIFT_TEST_KEYS: takes its license public key from the
# environment. For server/prove.js only; never installed or packaged.
nightshift-testkey: main.m $(SHARED)
	clang $(CFLAGS) -DNIGHTSHIFT_TEST_KEYS $(LDLIBS) -o $@ main.m NightShift.m

$(BUNDLED): nightshiftd Info.plist
	mkdir -p $(dir $@)
	cp Info.plist $(APP)/Contents/
	cp nightshiftd $@
	sh scripts/dev-sign.sh $(APP)

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
	codesign --force --options runtime --sign - $(STAGE)/bin/nightshift
	ditto -c -k --norsrc $(STAGE) $(ZIP)
	rm -rf $(STAGE)
	@echo $(ZIP) $(VERSION)

clean:
	rm -rf nightshift nightshiftd nightshift-tests logic-tests nightshift-testkey $(APP) $(DIST)

icon-lab:
	open prototype/icon/index.html

.PHONY: all test server-test install package clean icon-lab
