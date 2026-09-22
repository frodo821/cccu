.PHONY: build test release clean

build:            ## debug build (also used by tests)
	swift build

APP = .build/release/cccu-helper.app

release:          ## app bundle at .build/release/cccu-helper.app (signed with a stable identity)
	swift build -c release
	$(MAKE) bundle
	$(MAKE) sign

bundle:           ## wrap the binary in a minimal .app so TCC treats it as an app (Screen Recording needs this)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/cccu-helper $(APP)/Contents/MacOS/cccu-helper
	cp Info.plist $(APP)/Contents/Info.plist

e2e-chrome:       ## drives the user's running Chrome (opens and closes a tab)
	CCCU_E2E_CHROME=1 swift test --filter ChromeAXE2ETests

e2e:              ## drives TextEdit for real
	CCCU_E2E=1 swift test --filter TextEditE2ETests

test: build       ## unit + binary integration tests
	swift test

clean:
	rm -rf .build

sign:             ## sign with a stable identity so TCC remembers the helper across rebuilds
	../../bin/cccu-sign $(APP)
