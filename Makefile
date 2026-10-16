SDK := $(shell xcrun --show-sdk-path)
CFLAGS := -fobjc-arc -Wall -Wextra -F$(SDK)/System/Library/PrivateFrameworks
LDLIBS := -framework Foundation -framework CoreBrightness -framework Security
PREFIX ?= /usr/local
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
SHARED := NightShift.m NightShift.h CBBlueLightClient.h
LOGIC := NightshiftLogic.m NightshiftLogic.h
# The license server, compiled into nightshift and nightshiftd: an https
# origin, for example
#   make package LICENSE_SERVER=https://license.example.com
# Without it, those builds have no license server (buy and renew report it
# unreachable); make package refuses to run. The value goes to the compiler
# from the environment, never pasted into a shell command, and the test
# builds never see it.
LICENSE_SERVER ?=
export LICENSE_SERVER
SERVER_FLAGS = $(if $(LICENSE_SERVER),-DNIGHTSHIFT_LICENSE_SERVER="\"$$LICENSE_SERVER\"")
# The value the release binaries were built with. When it changes they are
# removed here, as the Makefile is read, so they are rebuilt: make 3.81
# compares whole seconds, so a newer stamp alone could be missed.
LICENSE_STAMP := .license-server
LICENSE_QUOTED := '$(subst ','\'',$(LICENSE_SERVER))'
$(shell printf '%s\n' $(LICENSE_QUOTED) | cmp -s - $(LICENSE_STAMP) || { rm -f nightshift nightshiftd; printf '%s\n' $(LICENSE_QUOTED) > $(LICENSE_STAMP); })
APP := Nightshift.app
BUNDLED := $(APP)/Contents/MacOS/nightshiftd
DIST := dist
STAGE := $(DIST)/root
ZIP := $(DIST)/Nightshift.zip

all: nightshift nightshiftd $(BUNDLED)

session-tap-check:
	python3 scripts/check-session-tap.py

test: socket-main-check session-tap-check secret-scan workspace-open-check nightshift nightshift-tests logic-tests server-test license-server-check
	./socket-main-check --siblings nightshiftd.m
	./nightshift-tests
	./logic-tests
	sh tests/cli.sh
	sh tests/license-server.sh

# Stripe-shaped values in the tracked tree, and the webhook source of truth.
# Prints file, line, and key name, never the value. server/.env is ignored.
secret-scan:
	sh scripts/scan-secrets.sh tree
	sh scripts/scan-secrets.sh self-test
	sh scripts/check-server-webhook.sh

# One NSWorkspace openURL:, and it calls both license verdicts.
workspace-open-check:
	sh scripts/check-workspace-open.sh

# glibc with -std=c11 declares mkdtemp only when _POSIX_C_SOURCE is at least
# 200809L. Apple's headers hide mkdtemp when that macro is set, so Darwin
# leaves it off. The check itself is unchanged.
socket-main-check: tests/socket-main-check.c
	cc -std=c11 -Wall -Wextra -Werror $(if $(filter Darwin,$(shell uname -s)),,-D_POSIX_C_SOURCE=200809L) -o $@ tests/socket-main-check.c

# The license server's tests: test.js needs only Node; prove.js also runs
# the license command of nightshift-testkey. Both sign with a throwaway key.
server-test: nightshift-testkey
	@test -d server/node_modules || { echo "server/node_modules is missing: run (cd server && npm ci)" >&2; exit 1; }
	cd server && node test.js
	cd server && node prove.js

nightshift: main.m $(SHARED) $(LOGIC) $(LICENSE_STAMP)
	clang $(CFLAGS) $(SERVER_FLAGS) $(LDLIBS) -o $@ main.m NightShift.m NightshiftLogic.m

SESSION_TAP := NightshiftSessionTap.m NightshiftSessionTap.h

nightshiftd: nightshiftd.m $(SHARED) $(LOGIC) $(SESSION_TAP) $(LICENSE_STAMP)
	clang $(CFLAGS) $(SERVER_FLAGS) $(LDLIBS) -framework AppKit -framework Carbon -framework UserNotifications -framework ServiceManagement -framework CoreGraphics -framework SkyLight -o $@ nightshiftd.m NightShift.m NightshiftLogic.m NightshiftSessionTap.m

nightshift-tests: tests/check.m $(SHARED) $(LOGIC)
	clang $(CFLAGS) -I. $(LDLIBS) -o $@ tests/check.m NightShift.m NightshiftLogic.m

logic-tests: tests/logic.m $(LOGIC)
	clang $(CFLAGS) -I. -o $@ tests/logic.m NightshiftLogic.m

# The CLI with NIGHTSHIFT_TEST_KEYS: takes its license public key from the
# environment. For server/prove.js only; never installed or packaged.
nightshift-testkey: main.m $(SHARED) $(LOGIC)
	clang $(CFLAGS) -DNIGHTSHIFT_TEST_KEYS $(LDLIBS) -o $@ main.m NightShift.m NightshiftLogic.m

# Checks LICENSE_SERVER with the app's own rule, for make package.
license-server-check: scripts/license-server-check.m $(LOGIC)
	clang $(CFLAGS) -I. -o $@ scripts/license-server-check.m NightshiftLogic.m

$(BUNDLED): nightshiftd Info.plist
	mkdir -p $(dir $@)
	cp Info.plist $(APP)/Contents/
	cp nightshiftd $@
	sh scripts/dev-sign.sh $(APP)

install: all license-server-check
	@./license-server-check install
	install -d $(PREFIX)/bin
	install -m 755 nightshift $(PREFIX)/bin
	rm -rf $(PREFIX)/Nightshift.app
	cp -R Nightshift.app $(PREFIX)/Nightshift.app

# A release must carry a usable license server: checked before anything is
# built, so a bad or missing LICENSE_SERVER stops here with the reason.
package: license-server-check
	./license-server-check package
	$(MAKE) all
	rm -rf $(STAGE) $(ZIP)
	mkdir -p $(STAGE)/bin
	install -m 755 nightshift $(STAGE)/bin/nightshift
	cp -R $(APP) $(STAGE)/
	codesign --force --options runtime --sign - $(STAGE)/bin/nightshift
	ditto -c -k --norsrc $(STAGE) $(ZIP)
	rm -rf $(STAGE)
	@echo $(ZIP) $(VERSION)

clean:
	rm -rf nightshift nightshiftd nightshift-tests logic-tests nightshift-testkey \
	    socket-main-check license-server-check $(LICENSE_STAMP) $(APP) $(DIST)

# Turns on scripts/hooks (the pre-commit secret scan) for this clone.
hooks:
	git config core.hooksPath scripts/hooks

icon-lab:
	open prototype/icon/index.html

.PHONY: all test server-test session-tap-check install package clean hooks icon-lab secret-scan workspace-open-check
