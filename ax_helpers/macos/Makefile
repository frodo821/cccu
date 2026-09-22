.PHONY: build test release clean

build:            ## debug build (also used by tests)
	swift build

release:          ## release binary at .build/release/cccu-helper
	swift build -c release

test: build       ## unit + binary integration tests
	swift test

clean:
	rm -rf .build
