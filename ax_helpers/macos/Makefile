.PHONY: build test release clean

build:            ## debug build (also used by tests)
	swift build

release:          ## release binary at .build/release/cccu-helper
	swift build -c release

e2e:              ## drives TextEdit for real
	CCCU_E2E=1 swift test --filter TextEditE2ETests

test: build       ## unit + binary integration tests
	swift test

clean:
	rm -rf .build
